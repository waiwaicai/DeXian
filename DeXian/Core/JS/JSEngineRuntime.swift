import Foundation
import JavaScriptCore
import Security

/// 书源 JS 环境里「Java 侧」的扩展实现。
///
/// 与 JSEngine.swift 分开，是因为这里全部是「书源真的会调用到、但原来完全没实现」
/// 的 API：字节数组互转、摘要 / HMAC、对称加解密、jsoup、ajaxAll 等。
///
/// 两点约束贯穿全文件：
///
/// 1. **所有闭包一律 [weak self]**，用 self?.context 取上下文。
///    直接强捕获 context 会形成 JSContext → JS 全局对象 → block → JSContext
///    的自锁，引擎永不释放。搜索每跑一个书源就泄漏一个虚拟机，
///    搜到近百个源时 JavaScriptCore 分配失败走 CRASH()，表现为「搜到某个数量必崩」。
/// 2. **绝不构造 JSValue(undefinedIn: nil)**。context 不可用时返回
///    JSValue()（空值），它在 JavaScriptCore 里等价于 undefined，
///    且不会触发 JSC 内部的断点陷阱。
extension JSEngine {

    /// 把 JSValue 视作 Java 的 byte[]（有符号 -128..127）取出来。
    ///
    /// 书源里 java.strToBytes(...) 的结果会被当作 Java byte[] 使用：
    /// bytes[i] & 255、Arrays.copyOf、AES 密钥等。
    /// Java 的 byte 是**有符号**的，所以这里按 Int8 的补码语义还原。
    static func dataFromJS(_ value: JSValue?) -> Data {
        guard let value, !value.isUndefined, !value.isNull else { return Data() }
        if value.isString {
            return Data((value.toString() ?? "").utf8)
        }
        if value.isArray, let array = value.toArray() {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(array.count)
            for item in array {
                let number = (item as? NSNumber)?.intValue ?? Int(RuleUtil.asDouble(item) ?? 0)
                bytes.append(UInt8(truncatingIfNeeded: number))
            }
            return Data(bytes)
        }
        return Data((value.toString() ?? "").utf8)
    }

    /// 把 Data 作为 Java byte[] 交给 JS：每项都是 -128..127 的有符号整数。
    static func jsBytes(_ data: Data, in context: JSContext) -> JSValue {
        let values: [NSNumber] = data.map { NSNumber(value: Int8(bitPattern: $0)) }
        if let array = JSValue(object: values, in: context) { return array }
        if let array = JSValue(newArrayIn: context) { return array }
        return JSValue()
    }

    /// 读出一个「可选字符串参数」。
    static func optionalString(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        let text = stringFrom(value)
        return text.isEmpty ? nil : text
    }

    // MARK: - 安装入口

    /// 安装扩展 Java API。必须在 setupJava 之后调用（需要复用已建好的桥）。
    func installExtendedJava() {
        guard let context, let java = context.objectForKeyedSubscript("java"), !java.isUndefined else { return }
        installBytePrimitives(java)
        installCryptoPrimitives(java)
        installJavaConvenience(java)
        installJsoup(java)
        installNetworkExtras(java)
        installMisc(java)
        // 供 JS 薄层使用的隐藏命名空间（不是书源 API）
        context.setObject(JSRuntimePrimitives.bridge(engine: self), forKeyedSubscript: "__dx" as NSString)
    }

    // MARK: - 字节 / 编码

    private func installBytePrimitives(_ java: JSValue) {
        // java.strToBytes(str, charset?)
        let strToBytes: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] value, charsetValue in
            guard let context = self?.context else { return JSValue() }
            let text = JSEngine.stringFrom(value)
            let encoding = Charset.encoding(named: JSEngine.optionalString(charsetValue) ?? "utf-8") ?? .utf8
            let data = text.data(using: encoding) ?? Data(text.utf8)
            return JSEngine.jsBytes(data, in: context)
        }
        java.setObject(strToBytes, forKeyedSubscript: "strToBytes" as NSString)

        // java.bytesToStr(bytes, charset?)
        let bytesToStr: @convention(block) (JSValue, JSValue) -> String = { value, charsetValue in
            let encoding = Charset.encoding(named: JSEngine.optionalString(charsetValue) ?? "utf-8") ?? .utf8
            let data = JSEngine.dataFromJS(value)
            return String(data: data, encoding: encoding) ?? JSEngine.cleanDecryptedString(data)
        }
        java.setObject(bytesToStr, forKeyedSubscript: "bytesToStr" as NSString)

        // java.base64DecodeToByteArray(str) -> byte[]
        let base64DecodeToByteArray: @convention(block) (JSValue) -> JSValue = { [weak self] value in
            guard let context = self?.context else { return JSValue() }
            let text = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data()
            return JSEngine.jsBytes(data, in: context)
        }
        java.setObject(base64DecodeToByteArray, forKeyedSubscript: "base64DecodeToByteArray" as NSString)

        // java.base64EncodeByteArray(bytes)
        let base64EncodeByteArray: @convention(block) (JSValue) -> String = { value in
            JSEngine.dataFromJS(value).base64EncodedString()
        }
        java.setObject(base64EncodeByteArray, forKeyedSubscript: "base64EncodeByteArray" as NSString)

        // java.hexDecodeToString(hex) —— 书源里出现 20 多次的取正文地址写法
        let hexDecodeToString: @convention(block) (JSValue) -> String = { value in
            JSEngine.cleanDecryptedString(CryptoHelper.hexToData(JSEngine.stringFrom(value)))
        }
        java.setObject(hexDecodeToString, forKeyedSubscript: "hexDecodeToString" as NSString)

        // java.hexDecodeToByteArray(hex)
        let hexDecodeToByteArray: @convention(block) (JSValue) -> JSValue = { [weak self] value in
            guard let context = self?.context else { return JSValue() }
            return JSEngine.jsBytes(CryptoHelper.hexToData(JSEngine.stringFrom(value)), in: context)
        }
        java.setObject(hexDecodeToByteArray, forKeyedSubscript: "hexDecodeToByteArray" as NSString)

        // java.hexEncodeToString(str)
        let hexEncodeToString: @convention(block) (JSValue) -> String = { value in
            Data(JSEngine.stringFrom(value).utf8).map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(hexEncodeToString, forKeyedSubscript: "hexEncodeToString" as NSString)

        // java.base64Decoder() —— 少数源按旧接口调用
        let base64Decoder: @convention(block) (JSValue) -> String = { value in
            let text = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data()
            return JSEngine.cleanDecryptedString(data)
        }
        java.setObject(base64Decoder, forKeyedSubscript: "base64Decoder" as NSString)
    }


    // MARK: - 摘要 / HMAC / 对称加密

    private func installCryptoPrimitives(_ java: JSValue) {
        // java.HMacHex(...) / java.HMacBase64(...)
        // 参数顺序在不同书源里不一致，这里做一次保守的「谁像算法名」识别。
        let hmacHexBlock: @convention(block) (JSValue, JSValue, JSValue) -> String = { first, second, third in
            guard let parts = JSEngine.hmacArguments(first, second, third) else { return "" }
            return Crypto.hmacHex(parts.data, algorithm: parts.algorithm, key: parts.key)
        }
        java.setObject(hmacHexBlock, forKeyedSubscript: "HMacHex" as NSString)

        let hmacBase64Block: @convention(block) (JSValue, JSValue, JSValue) -> String = { first, second, third in
            guard let parts = JSEngine.hmacArguments(first, second, third) else { return "" }
            let hex = Crypto.hmacHex(parts.data, algorithm: parts.algorithm, key: parts.key)
            return CryptoHelper.hexToData(hex).base64EncodedString()
        }
        java.setObject(hmacBase64Block, forKeyedSubscript: "HMacBase64" as NSString)

        // java.digestHex(data, algorithm)
        let digestHexBlock: @convention(block) (JSValue, JSValue) -> String = { data, algorithm in
            let text = JSEngine.stringFrom(data)
            let name = JSEngine.stringFrom(algorithm)
            if JSEngine.looksLikeDigestAlgorithm(name) {
                return Crypto.digestHex(text, algorithm: name)
            }
            // 参数颠倒（algorithm 在前）时兜底
            if JSEngine.looksLikeDigestAlgorithm(text) {
                return Crypto.digestHex(JSEngine.stringFrom(algorithm), algorithm: text)
            }
            return Crypto.digestHex(text, algorithm: name.isEmpty ? "SHA256" : name)
        }
        java.setObject(digestHexBlock, forKeyedSubscript: "digestHex" as NSString)

        // java.createSymmetricCrypto(transformation, key, iv) -> SymmetricCrypto
        let createSymmetricCrypto: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self] transformation, key, iv in
            // makeSymmetricCrypto 自己会校验 context 是否还在，这里只传引擎。
            guard let self else { return JSValue() }
            return JSEngine.makeSymmetricCrypto(
                engine: self,
                transformation: JSEngine.stringFrom(transformation),
                keyValue: key,
                ivValue: iv
            )
        }
        java.setObject(createSymmetricCrypto, forKeyedSubscript: "createSymmetricCrypto" as NSString)

        // java.aesBase64DecodeToString(data, key, iv, transformation?)
        let aesBase64DecodeToString: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { data, key, iv, transformation in
            JSEngine.symmetricDecryptToString(
                cipher: JSEngine.cipherBytesFrom(data),
                keyValue: key,
                ivValue: iv,
                transformation: JSEngine.optionalString(transformation) ?? "AES/CBC/PKCS5Padding"
            )
        }
        java.setObject(aesBase64DecodeToString, forKeyedSubscript: "aesBase64DecodeToString" as NSString)

        // java.aesDecodeToString(data, key, iv, transformation?) —— 不补填充
        let aesDecodeToString: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { data, key, iv, transformation in
            let name = JSEngine.optionalString(transformation) ?? "AES/CBC/PKCS5Padding"
            let ivData = (iv.isUndefined || iv.isNull) ? nil : JSEngine.dataFromJS(iv)
            guard let output = CryptoHelper.decrypt(JSEngine.dataFromJS(data),
                                                    key: JSEngine.dataFromJS(key),
                                                    iv: ivData,
                                                    transformation: name,
                                                    padding: false) else { return "" }
            return JSEngine.cleanDecryptedString(output)
        }
        java.setObject(aesDecodeToString, forKeyedSubscript: "aesDecodeToString" as NSString)

        // java.tripleDESEncodeBase64Str(data, key, iv)
        let tripleDESEncodeBase64Str: @convention(block) (JSValue, JSValue, JSValue) -> String = { data, key, iv in
            let ivData = (iv.isUndefined || iv.isNull) ? nil : JSEngine.dataFromJS(iv)
            guard let output = CryptoHelper.encrypt(JSEngine.dataFromJS(data),
                                                    key: JSEngine.dataFromJS(key),
                                                    iv: ivData,
                                                    algorithm: .tripleDES,
                                                    mode: ivData == nil ? .ecb : .cbc,
                                                    padding: true) else { return "" }
            return output.base64EncodedString()
        }
        java.setObject(tripleDESEncodeBase64Str, forKeyedSubscript: "tripleDESEncodeBase64Str" as NSString)

        // java.createAsymmetricCrypto(...) —— 非对称加密在书源里极罕见，
        // 给出结构完整但返回空串的对象，让书源走自己的 try/catch 分支，
        // 而不是因为「方法不存在」直接崩掉整条规则链。
        let createAsymmetricCrypto: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] _, _ in
            guard let context = self?.context else { return JSValue() }
            let object = JSEngine.newObject(in: context)
            let fail: @convention(block) (JSValue) -> String = { _ in "" }
            for name in ["encryptBase64", "decryptStr", "encrypt", "decrypt", "encryptStr", "decryptBase64Str"] {
                object.setObject(fail, forKeyedSubscript: name as NSString)
            }
            return object
        }
        java.setObject(createAsymmetricCrypto, forKeyedSubscript: "createAsymmetricCrypto" as NSString)
    }

    // MARK: - Java 便利方法

    private func installJavaConvenience(_ java: JSValue) {
        let randomUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        java.setObject(randomUUID, forKeyedSubscript: "randomUUID" as NSString)

        // java.toNumChapter("第12章") -> 12
        let toNumChapter: @convention(block) (JSValue) -> Int = { value in
            Int(JSEngine.stringFrom(value).filter { $0.isNumber }) ?? 0
        }
        java.setObject(toNumChapter, forKeyedSubscript: "toNumChapter" as NSString)

        // java.timeFormatUTC(timestamp, format)
        let timeFormatUTC: @convention(block) (JSValue, JSValue) -> String = { time, format in
            let timestamp = RuleUtil.asDouble(JSEngine.swiftValue(time)) ?? Date().timeIntervalSince1970
            let seconds = timestamp > 1e12 ? timestamp / 1000 : timestamp
            var pattern = JSEngine.stringFrom(format)
            if pattern.isEmpty { pattern = "yyyy-MM-dd HH:mm:ss" }
            pattern = pattern.replacingOccurrences(of: "YYYY", with: "yyyy")
            pattern = pattern.replacingOccurrences(of: "DD", with: "dd")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = pattern
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        java.setObject(timeFormatUTC, forKeyedSubscript: "timeFormatUTC" as NSString)

        // java.sleep(ms)
        let sleep: @convention(block) (JSValue) -> Void = { value in
            let milliseconds = value.toDouble()
            guard milliseconds > 0, milliseconds <= 5000 else { return }
            Thread.sleep(forTimeInterval: milliseconds / 1000)
        }
        java.setObject(sleep, forKeyedSubscript: "sleep" as NSString)

        // java.ajaxAll(list) -> 逐个请求，返回字符串数组
        let ajaxAll: @convention(block) (JSValue) -> [String] = { [weak self] value in
            guard let self, let list = value.toArray() else { return [] }
            var output: [String] = []
            for item in list.prefix(50) {
                let url = RuleUtil.asString(item) ?? ""
                guard !url.isEmpty else { continue }
                let response = self.connect(url: url, header: nil, method: nil, body: nil)
                output.append(response.objectForKeyedSubscript("__text")?.toString() ?? "")
            }
            return output
        }
        java.setObject(ajaxAll, forKeyedSubscript: "ajaxAll" as NSString)
        java.setObject(ajaxAll, forKeyedSubscript: "ajaxTestAll" as NSString)

        // java.getStrResponse(url, header)
        let getStrResponse: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] urlValue, headerValue in
            guard let self else { return JSValue() }
            return self.connect(url: JSEngine.stringFrom(urlValue), header: headerValue, method: "GET", body: nil)
        }
        java.setObject(getStrResponse, forKeyedSubscript: "getStrResponse" as NSString)

        // java.head(url, header)
        let head: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] urlValue, headerValue in
            guard let self else { return JSValue() }
            return self.connect(url: JSEngine.stringFrom(urlValue), header: headerValue, method: "HEAD", body: nil)
        }
        java.setObject(head, forKeyedSubscript: "head" as NSString)

        // java.htmlFormat(text)
        let htmlFormat: @convention(block) (JSValue) -> String = { value in
            JSEngine.stringFrom(value).replacingOccurrences(of: "\r\n", with: "\n")
        }
        java.setObject(htmlFormat, forKeyedSubscript: "htmlFormat" as NSString)

        // java.queryBase64TTF / queryTTF —— 字体反爬，可降级
        let queryBase64TTF: @convention(block) (JSValue) -> JSValue = { [weak self] _ in
            guard let context = self?.context else { return JSValue() }
            return JSValue(nullIn: context) ?? JSValue()
        }
        java.setObject(queryBase64TTF, forKeyedSubscript: "queryBase64TTF" as NSString)
    }


    // MARK: - jsoup

    private func installJsoup(_ java: JSValue) {
        // java.__jsoupParse(html) -> Document 包装对象
        let parse: @convention(block) (JSValue) -> JSValue = { [weak self] htmlValue in
            // wrapElement 在引擎已释放时会返回空值，这里不需要额外持有 context。
            guard let self else { return JSValue() }
            let document = HTMLParser.parse(JSEngine.stringFrom(htmlValue))
            return self.wrapElement(document)
        }
        java.setObject(parse, forKeyedSubscript: "__jsoupParse" as NSString)

        // java.__rawInflate(bytes) -> bytes（书源里手写 zip 解包会用）
        let rawInflate: @convention(block) (JSValue) -> JSValue = { [weak self] value in
            guard let context = self?.context else { return JSValue() }
            let inflated = GzipDecompressor.inflate(JSEngine.dataFromJS(value)) ?? Data()
            return JSEngine.jsBytes(inflated, in: context)
        }
        java.setObject(rawInflate, forKeyedSubscript: "__rawInflate" as NSString)

        // java.__randomBytes(n) -> bytes
        let randomBytes: @convention(block) (JSValue) -> JSValue = { [weak self] value in
            guard let context = self?.context else { return JSValue() }
            let count = max(0, min(64, Int(value.toInt32())))
            var bytes = [UInt8](repeating: 0, count: count)
            if count > 0 { _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes) }
            return JSEngine.jsBytes(Data(bytes), in: context)
        }
        java.setObject(randomBytes, forKeyedSubscript: "__randomBytes" as NSString)
    }

    // MARK: - 网络扩展

    private func installNetworkExtras(_ java: JSValue) {
        // java.webView(html, url, ...) —— 需要真实 WebView 才能执行页面脚本。
        // 这里退化为「把传入的 HTML 当作响应文本」，而不是抛异常让整条规则链断掉。
        let webView: @convention(block) (JSValue, JSValue) -> String = { htmlValue, _ in
            JSEngine.stringFrom(htmlValue)
        }
        java.setObject(webView, forKeyedSubscript: "webView" as NSString)
        java.setObject(webView, forKeyedSubscript: "webview" as NSString)

        let showBrowser: @convention(block) (JSValue, JSValue) -> Void = { _, _ in }
        java.setObject(showBrowser, forKeyedSubscript: "showBrowser" as NSString)
    }

    // MARK: - 其余桩

    private func installMisc(_ java: JSValue) {
        let copyText: @convention(block) (JSValue) -> Void = { value in
            Log.debugLog("JS", "copyText: " + String(JSEngine.stringFrom(value).prefix(80)))
        }
        java.setObject(copyText, forKeyedSubscript: "copyText" as NSString)

        let androidId: @convention(block) () -> String = { "dexian-ios" }
        java.setObject(androidId, forKeyedSubscript: "androidId" as NSString)

        let getVerificationCode: @convention(block) () -> String = { "" }
        java.setObject(getVerificationCode, forKeyedSubscript: "getVerificationCode" as NSString)

        let noop: @convention(block) (JSValue) -> Void = { _ in }
        for name in ["openBook", "openVideoPlayer", "openWeb", "reLoginView", "initUrl", "downloadFile", "readTxtFile", "searchBook"] {
            java.setObject(noop, forKeyedSubscript: name as NSString)
        }

        let open: @convention(block) (JSValue) -> Void = { value in
            Log.debugLog("JS", "open: " + JSEngine.stringFrom(value))
        }
        java.setObject(open, forKeyedSubscript: "open" as NSString)
    }

    // MARK: - 辅助

    /// 参数看起来是不是摘要算法名（用于参数顺序不一致的书源）。
    static func looksLikeDigestAlgorithm(_ text: String) -> Bool {
        let upper = text.uppercased().replacingOccurrences(of: "-", with: "")
        return ["MD5", "SHA1", "SHA256", "SHA384", "SHA512", "HMAC"].contains { upper.contains($0) }
    }

    /// 归一化 HMacHex / HMacBase64 的三个参数。
    struct HmacArguments {
        var algorithm: String
        var data: String
        var key: String
    }

    static func hmacArguments(_ first: JSValue, _ second: JSValue, _ third: JSValue) -> HmacArguments? {
        let values = [first, second, third]
        guard let algorithmValue = values.first(where: { looksLikeDigestAlgorithm(stringFrom($0)) }) else {
            return nil
        }
        var rest = values
        if let index = rest.firstIndex(where: { $0 === algorithmValue }) { rest.remove(at: index) }
        guard rest.count >= 2 else { return nil }
        return HmacArguments(algorithm: stringFrom(algorithmValue),
                             data: stringFrom(rest[0]),
                             key: stringFrom(rest[1]))
    }

    /// 解密结果里的字节可能不是合法 UTF-8（例如密钥不对）。
    /// 先试 UTF-8；失败再按 GB18030 试一次 —— 中文站点大量使用 GBK，
    /// 只用 UTF-8 会把能救回来的正文变成空串，用户看到的就是「正文乱码 / 空白」。
    static func cleanDecryptedString(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        // GB18030 不能用 String.Encoding.gb_18030_2000：那个常量只在 macOS 上存在，
        // iOS SDK 里没有，直接用会编译失败。统一走 Charset 的 CFString 转换。
        if let gb = Charset.encoding(named: "gb18030"),
           let text = String(data: data, encoding: gb) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return ""
    }

    /// 把一个「可能是 Base64 文本、也可能是字节数组」的参数取成密文字节。
    static func cipherBytesFrom(_ value: JSValue?) -> Data {
        guard let value, !value.isUndefined, !value.isNull else { return Data() }
        if value.isString {
            let text = stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) { return data }
            return Data(text.utf8)
        }
        return dataFromJS(value)
    }

    /// 对称解密并文本化（含 GBK 兜底）。
    static func symmetricDecryptToString(
        cipher: Data,
        keyValue: JSValue,
        ivValue: JSValue,
        transformation: String
    ) -> String {
        let ivData = (ivValue.isUndefined || ivValue.isNull) ? nil : dataFromJS(ivValue)
        guard let output = CryptoHelper.decrypt(cipher,
                                               key: dataFromJS(keyValue),
                                               iv: ivData,
                                               transformation: transformation,
                                               padding: true) else {
            Log.debugLog("JS", "对称解密失败 transformation=" + transformation)
            return ""
        }
        return cleanDecryptedString(output)
    }

    /// 构造 java.createSymmetricCrypto(...) 返回的对象。
    static func makeSymmetricCrypto(
        engine: JSEngine,
        transformation: String,
        keyValue: JSValue,
        ivValue: JSValue
    ) -> JSValue {
        guard let context = engine.context else { return JSValue() }
        let keyBytes = dataFromJS(keyValue)
        let ivData = (ivValue.isUndefined || ivValue.isNull) ? nil : dataFromJS(ivValue)
        let name = transformation.isEmpty ? "AES/CBC/PKCS5Padding" : transformation

        let object = newObject(in: context)

        let encryptBlock: @convention(block) (JSValue) -> JSValue = { [weak engine] data in
            guard let context = engine?.context else { return JSValue() }
            let output = CryptoHelper.encrypt(dataFromJS(data), key: keyBytes, iv: ivData,
                                              transformation: name, padding: true)
            return jsBytes(output ?? Data(), in: context)
        }
        object.setObject(encryptBlock, forKeyedSubscript: "encrypt" as NSString)

        let encryptBase64Block: @convention(block) (JSValue) -> String = { data in
            CryptoHelper.encrypt(dataFromJS(data), key: keyBytes, iv: ivData,
                                 transformation: name, padding: true)?.base64EncodedString() ?? ""
        }
        for key in ["encryptBase64", "encryptStr", "encryptBase64Str", "encryptToString"] {
            object.setObject(encryptBase64Block, forKeyedSubscript: key as NSString)
        }

        let encryptHexBlock: @convention(block) (JSValue) -> String = { data in
            CryptoHelper.encrypt(dataFromJS(data), key: keyBytes, iv: ivData,
                                 transformation: name, padding: true)?
                .map { String(format: "%02x", $0) }.joined() ?? ""
        }
        object.setObject(encryptHexBlock, forKeyedSubscript: "encryptHex" as NSString)

        let decryptBlock: @convention(block) (JSValue) -> JSValue = { [weak engine] data in
            guard let context = engine?.context else { return JSValue() }
            let output = CryptoHelper.decrypt(cipherBytesFrom(data), key: keyBytes, iv: ivData,
                                              transformation: name, padding: true)
            return jsBytes(output ?? Data(), in: context)
        }
        object.setObject(decryptBlock, forKeyedSubscript: "decrypt" as NSString)

        let decryptStrBlock: @convention(block) (JSValue) -> String = { data in
            guard let output = CryptoHelper.decrypt(cipherBytesFrom(data), key: keyBytes, iv: ivData,
                                                    transformation: name, padding: true) else { return "" }
            return cleanDecryptedString(output)
        }
        for key in ["decryptStr", "decryptToString", "decryptBase64Str"] {
            object.setObject(decryptStrBlock, forKeyedSubscript: key as NSString)
        }

        let decryptHexBlock: @convention(block) (JSValue) -> String = { data in
            CryptoHelper.decrypt(cipherBytesFrom(data), key: keyBytes, iv: ivData,
                                 transformation: name, padding: true)?
                .map { String(format: "%02x", $0) }.joined() ?? ""
        }
        object.setObject(decryptHexBlock, forKeyedSubscript: "decryptHex" as NSString)

        return object
    }
}


/// 暴露给 JS 薄层的底层原语。
///
/// JS 侧的 CryptoJS 兼容层、Packages.javax.crypto.Cipher 都通过这里落到
/// CommonCrypto / Compression 上，避免用 JS 重新实现一遍分组密码。
///
/// 所有闭包都用 [weak engine] 取上下文：这些闭包最终挂在 JSContext 的全局对象上，
/// 强引用 JSContext 会形成自锁，导致引擎（及其 JSVirtualMachine）永不释放。
enum JSRuntimePrimitives {

    static func bridge(engine: JSEngine) -> JSValue {
        guard let context = engine.context else { return JSValue() }
        let object = JSEngine.newObject(in: context)

        let u8: @convention(block) (JSValue) -> JSValue = { [weak engine] value in
            guard let context = engine?.context else { return JSValue() }
            return JSEngine.jsBytes(Data(JSEngine.stringFrom(value).utf8), in: context)
        }
        object.setObject(u8, forKeyedSubscript: "u8" as NSString)

        let s8: @convention(block) (JSValue) -> String = { value in
            JSEngine.cleanDecryptedString(JSEngine.dataFromJS(value))
        }
        object.setObject(s8, forKeyedSubscript: "s8" as NSString)

        let b64d: @convention(block) (JSValue) -> JSValue = { [weak engine] value in
            guard let context = engine?.context else { return JSValue() }
            let text = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data()
            return JSEngine.jsBytes(data, in: context)
        }
        object.setObject(b64d, forKeyedSubscript: "b64d" as NSString)

        let b64e: @convention(block) (JSValue) -> String = { value in
            JSEngine.dataFromJS(value).base64EncodedString()
        }
        object.setObject(b64e, forKeyedSubscript: "b64e" as NSString)

        let hexd: @convention(block) (JSValue) -> JSValue = { [weak engine] value in
            guard let context = engine?.context else { return JSValue() }
            return JSEngine.jsBytes(CryptoHelper.hexToData(JSEngine.stringFrom(value)), in: context)
        }
        object.setObject(hexd, forKeyedSubscript: "hexd" as NSString)

        let hexe: @convention(block) (JSValue) -> String = { value in
            JSEngine.dataFromJS(value).map { String(format: "%02x", $0) }.joined()
        }
        object.setObject(hexe, forKeyedSubscript: "hexe" as NSString)

        // JS 侧把「按字符编码取字节」也交给原生，保证与 Java getBytes(charset) 一致
        let u8cs: @convention(block) (JSValue, JSValue) -> JSValue = { [weak engine] value, charsetValue in
            guard let context = engine?.context else { return JSValue() }
            let text = JSEngine.stringFrom(value)
            let encoding = Charset.encoding(named: JSEngine.optionalString(charsetValue) ?? "utf-8") ?? .utf8
            return JSEngine.jsBytes(text.data(using: encoding) ?? Data(text.utf8), in: context)
        }
        object.setObject(u8cs, forKeyedSubscript: "u8cs" as NSString)

        let bytesToStr: @convention(block) (JSValue, JSValue) -> String = { value, charsetValue in
            let encoding = Charset.encoding(named: JSEngine.optionalString(charsetValue) ?? "utf-8") ?? .utf8
            let data = JSEngine.dataFromJS(value)
            return String(data: data, encoding: encoding) ?? JSEngine.cleanDecryptedString(data)
        }
        object.setObject(bytesToStr, forKeyedSubscript: "bytesToStr" as NSString)

        let digest: @convention(block) (JSValue, JSValue) -> JSValue = { [weak engine] algorithm, data in
            guard let context = engine?.context else { return JSValue() }
            let hex = Crypto.digestHex(JSEngine.stringFrom(data), algorithm: JSEngine.stringFrom(algorithm))
            return JSEngine.jsBytes(CryptoHelper.hexToData(hex), in: context)
        }
        object.setObject(digest, forKeyedSubscript: "digest" as NSString)
        object.setObject(digest, forKeyedSubscript: "digestBytes" as NSString)

        let hmac: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak engine] algorithm, data, key in
            guard let context = engine?.context else { return JSValue() }
            let hex = Crypto.hmacHex(JSEngine.stringFrom(data),
                                     algorithm: JSEngine.stringFrom(algorithm),
                                     key: JSEngine.stringFrom(key))
            return JSEngine.jsBytes(CryptoHelper.hexToData(hex), in: context)
        }
        object.setObject(hmac, forKeyedSubscript: "hmac" as NSString)
        object.setObject(hmac, forKeyedSubscript: "hmacBytes" as NSString)

        // cipher(encrypt?, transformation, keyBytes, dataBytes, ivBytes) -> bytes
        let cipher: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> JSValue = { [weak engine] operation, transformation, key, data, iv in
            guard let context = engine?.context else { return JSValue() }
            let name = JSEngine.stringFrom(transformation)
            let ivData = (iv.isUndefined || iv.isNull) ? nil : JSEngine.dataFromJS(iv)
            let payload = JSEngine.dataFromJS(data)
            let keyBytes = JSEngine.dataFromJS(key)
            let output: Data?
            if operation.toBool() {
                output = CryptoHelper.encrypt(payload, key: keyBytes, iv: ivData, transformation: name, padding: true)
            } else {
                output = CryptoHelper.decrypt(payload, key: keyBytes, iv: ivData, transformation: name, padding: true)
            }
            return JSEngine.jsBytes(output ?? Data(), in: context)
        }
        object.setObject(cipher, forKeyedSubscript: "cipher" as NSString)

        let rawInflate: @convention(block) (JSValue) -> JSValue = { [weak engine] value in
            guard let context = engine?.context else { return JSValue() }
            return JSEngine.jsBytes(GzipDecompressor.inflate(JSEngine.dataFromJS(value)) ?? Data(), in: context)
        }
        object.setObject(rawInflate, forKeyedSubscript: "rawInflate" as NSString)

        let randomBytes: @convention(block) (JSValue) -> JSValue = { [weak engine] value in
            guard let context = engine?.context else { return JSValue() }
            let count = max(0, min(64, Int(value.toInt32())))
            var bytes = [UInt8](repeating: 0, count: count)
            if count > 0 { _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes) }
            return JSEngine.jsBytes(Data(bytes), in: context)
        }
        object.setObject(randomBytes, forKeyedSubscript: "randomBytes" as NSString)

        return object
    }
}
