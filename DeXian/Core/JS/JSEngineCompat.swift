import Foundation
import JavaScriptCore

/// 书源兼容层里「实测有调用、但引擎没实现」的那批 `java.*` API。
///
/// 依据：把 yckceo「阅读」分类近一年的 986 个条目（书源 / 书源合集 /
/// 订阅源 / 订阅源合集）全部下载后展开，得到 191552 个书源语料，
/// 逐条统计 `java.xxx(` 的调用点，再与本工程已注册的 API 求差集。
///
/// 缺口按「受影响书源数」排序，前几项是：
///
/// | API | 调用 | 影响源 |
/// |---|---|---|
/// | refreshTocUrl | 769 | 733 |
/// | deviceID | 649 | 322 |
/// | initUrl | 366 | 278 |
/// | importScript | 262 | 192 |
/// | refreshBookUrl | 212 | 212 |
/// | readTxtFile | 152 | 39 |
/// | startBrowserDp | 139 | 136 |
/// | showReadingBrowser | 133 | 123 |
/// | upLoginData | 88 | 75 |
///
/// 缺任何一个都不是「少个功能」，而是 undefined is not a function
/// 把整段脚本打断 —— 书源里这些调用普遍是**裸写**（不在 try/catch 里），
/// 一旦抛错，同一条 @js: 规则后面的代码全部不执行，
/// 表现就是「目录刷不出来 / 登录保存失败 / 段评按钮点了没反应」。
extension JSEngine {

    /// 安装缺失的书源 API。必须在 setupJava 与 installExtendedJava 之后调用。
    func installCompatJava() {
        guard let context, let java = context.objectForKeyedSubscript("java"),
              !java.isUndefined else { return }
        installCompatDevice(java)
        installCompatRefresh(java)
        installCompatScript(java)
        installCompatFile(java)
        installCompatCrypto(java)
        installCompatBrowser(java)
        installCompatNetwork(java)
        installCompatMisc(java)
    }

    // MARK: - 设备标识

    /// 环境探测型 API。
    ///
    /// - java.deviceID()：54 个源拿它当设备指纹注册账号。多数写成
    ///   try { deviceKey = java.deviceID() } catch(e) { deviceKey = java.androidId() }，
    ///   缺失时会落到 androidId（本工程返回固定串）也能跑通，
    ///   但另有 6 处是裸调用，缺失即中断。这里给一个稳定的本机标识。
    /// - java.qread()：源阅（轻阅读）专有 API，源里普遍写成
    ///   try { java.qread(); isqread = true } catch(e) {} 来探测运行环境。
    ///   **故意不注册** —— 注册了会让源误判自己跑在源阅上走进那条分支。
    /// - java.getAppVariant()：客户端变体号，书源据此选接口。
    /// - java.webViewUA()：WebView 的 UA，与 getUserAgent 同义。
    private func installCompatDevice(_ java: JSValue) {
        let deviceID: @convention(block) () -> String = {
            DeviceIdentity.identifier
        }
        java.setObject(deviceID, forKeyedSubscript: "deviceID" as NSString)

        let appVariant: @convention(block) () -> Int = { 1 }
        java.setObject(appVariant, forKeyedSubscript: "getAppVariant" as NSString)

        let webViewUA: @convention(block) () -> String = {
            JSEngine.webViewUserAgent
        }
        java.setObject(webViewUA, forKeyedSubscript: "webViewUA" as NSString)
    }

    // MARK: - 刷新类

    /// 刷新类 API：书源改动书籍 / 目录 / 正文地址后通知宿主重新拉取。
    ///
    /// 全部转发到 onRefreshRequest，由界面决定刷新什么。
    /// 「不刷新」和「调用即抛错」差别巨大：后者会打断脚本，
    /// 连同一规则里后续的字段赋值都跑不完。
    private func installCompatRefresh(_ java: JSValue) {
        let handler: @convention(block) (JSValue) -> Void = { [weak self] nameValue in
            self?.onRefreshRequest?(JSEngine.stringFrom(nameValue))
        }
        for name in ["refreshTocUrl", "refreshBookUrl", "refreshBookInfo", "refreshContent",
                     "refreshBook", "refreshtocurl"] {
            java.setObject(handler, forKeyedSubscript: name as NSString)
        }

        // 无参形式：脚本里的调用都没有实参，单独注册零参版本，
        // 避免部分书源用 java.refreshTocUrl.length 之类做参数个数判断。
        let noArg: @convention(block) () -> Void = { [weak self] in
            self?.onRefreshRequest?("")
        }
        for name in ["reGetBook", "refreshBookToc"] {
            java.setObject(noArg, forKeyedSubscript: name as NSString)
        }

        // java.setBaseUrl(url)：脚本改掉「当前页面地址」，后续相对地址据此解析。
        let setBaseUrl: @convention(block) (JSValue) -> Void = { [weak self] value in
            let url = JSEngine.stringFrom(value)
            guard !url.isEmpty else { return }
            self?.host.baseUrl = url
        }
        java.setObject(setBaseUrl, forKeyedSubscript: "setBaseUrl" as NSString)

        // java.redirectUrl / java.getRedirectUrl()：最后一次请求的真实地址。
        let getRedirectUrl: @convention(block) () -> String = { [weak self] in
            self?.lastResponse?.finalURL?.absoluteString ?? self?.host.baseUrl ?? ""
        }
        java.setObject(getRedirectUrl, forKeyedSubscript: "getRedirectUrl" as NSString)
    }

    // MARK: - 脚本导入

    /// java.importScript(urlOrPath)：拉取外部脚本 / 片段并返回其文本。
    ///
    /// 实测 192 个源用它引入公共函数库（评论模板、解密函数）。
    /// 是 URL 就联网取，否则当成本地脚本名从应用目录读。
    private func installCompatScript(_ java: JSValue) {
        let importScript: @convention(block) (JSValue) -> String = { [weak self] value in
            guard let self else { return "" }
            let target = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return "" }

            // 命中缓存直接返回：同一条规则在一次阅读里可能反复导入
            if let cached = self.cache[target], !cached.isEmpty { return cached }

            var text = ""
            if target.lowercased().hasPrefix("http") {
                let response = self.connect(url: target, header: nil, method: nil, body: nil)
                text = response.objectForKeyedSubscript("__text")?.toString() ?? ""
            } else {
                text = (try? String(contentsOf: FileStorage.url(target), encoding: .utf8)) ?? ""
            }
            if !text.isEmpty { self.cache[target] = text }
            return text
        }
        java.setObject(importScript, forKeyedSubscript: "importScript" as NSString)
    }
    // MARK: - 文件

    /// 文件类 API：读 / 删 / 下载 / 解压。
    ///
    /// readTxtFile 与 importScript 常配对使用：先 import 一个脚本，
    /// 再把内容写进本地文件、下次读回来当缓存（39 个源这么做）。
    private func installCompatFile(_ java: JSValue) {
        let readTxtFile: @convention(block) (JSValue) -> String = { value in
            let name = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "" }
            return (try? String(contentsOf: FileStorage.url(name), encoding: .utf8)) ?? ""
        }
        java.setObject(readTxtFile, forKeyedSubscript: "readTxtFile" as NSString)
        java.setObject(readTxtFile, forKeyedSubscript: "readFile" as NSString)

        let deleteFile: @convention(block) (JSValue) -> Void = { value in
            let name = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            try? FileManager.default.removeItem(at: FileStorage.url(name))
        }
        java.setObject(deleteFile, forKeyedSubscript: "deleteFile" as NSString)

        // java.downloadFile(url)：下载到应用目录并返回本地路径。
        let downloadFile: @convention(block) (JSValue) -> String = { [weak self] value in
            guard let self else { return "" }
            // 书源会写成 url + ", " + JSON.stringify({type:"mgg"})，
            // 逗号后面是选项不是地址，取第一段。
            let raw = JSEngine.stringFrom(value)
            let url = raw.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
            guard !url.isEmpty else { return "" }

            let response = self.connect(url: url, header: nil, method: nil, body: nil)
            let text = response.objectForKeyedSubscript("__text")?.toString() ?? ""
            guard !text.isEmpty else { return "" }

            let target = FileStorage.url("dexian-download-" + url.stableHash + ".txt")
            try? text.write(to: target, atomically: true, encoding: .utf8)
            return target.path
        }
        java.setObject(downloadFile, forKeyedSubscript: "downloadFile" as NSString)

        // java.cacheFile(url)：下载并缓存，返回内容。30 个源用它取详情 / 目录。
        let cacheFile: @convention(block) (JSValue) -> String = { [weak self] value in
            guard let self else { return "" }
            let url = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return "" }
            if let cached = self.cache["cacheFile:" + url] { return cached }
            let response = self.connect(url: url, header: nil, method: nil, body: nil)
            let text = response.objectForKeyedSubscript("__text")?.toString() ?? ""
            if !text.isEmpty { self.cache["cacheFile:" + url] = text }
            return text
        }
        java.setObject(cacheFile, forKeyedSubscript: "cacheFile" as NSString)

        // java.getZipStringContent(url, "detail.json")：从远端 zip 取条目。
        let getZipStringContent: @convention(block) (JSValue, JSValue) -> String = { [weak self] urlValue, entryValue in
            guard let self else { return "" }
            let url = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = JSEngine.stringFrom(entryValue)
            guard !url.isEmpty else { return "" }

            let key = "zip:" + url + "|" + entry
            if let cached = self.cache[key] { return cached }

            if let data = self.fetchZipData(url: url),
               let content = ZipArchive.content(of: entry, in: data) {
                let text = Charset.decode(content)
                if !text.isEmpty { self.cache[key] = text }
                return text
            }
            // 不是 zip（直接返回 JSON 的接口）：原样返回，交给后续规则解析。
            let text = self.connect(url: url, header: nil, method: nil, body: nil)
                .objectForKeyedSubscript("__text")?.toString() ?? ""
            if !text.isEmpty { self.cache[key] = text }
            return text
        }
        java.setObject(getZipStringContent, forKeyedSubscript: "getZipStringContent" as NSString)
    }
    // MARK: - 加解密

    /// 补齐几个「按 Java 方法名直译」的加解密入口。
    ///
    /// java.desEncodeToBase64String 一项就有 244 个源在用（968 处调用），
    /// 是覆盖面最广的缺口之一；调用形态统一是
    /// java.desEncodeToBase64String(data, key, "DES/ECB/PKCS5Padding", iv)。
    private func installCompatCrypto(_ java: JSValue) {
        // desEncodeToBase64String(data, key, transformation, iv)
        let desEncode: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { value, keyValue, transformationValue, ivValue in
            JSEngine.compatEncrypt(
                data: JSEngine.stringFrom(value),
                key: JSEngine.stringFrom(keyValue),
                transformation: JSEngine.stringFrom(transformationValue),
                iv: JSEngine.stringFrom(ivValue),
                defaultTransformation: "DES/ECB/PKCS5Padding"
            )
        }
        java.setObject(desEncode, forKeyedSubscript: "desEncodeToBase64String" as NSString)
        java.setObject(desEncode, forKeyedSubscript: "desEncodeBase64String" as NSString)

        // aesEncodeToBase64String(data, key, transformation, iv)
        let aesEncode: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { value, keyValue, transformationValue, ivValue in
            JSEngine.compatEncrypt(
                data: JSEngine.stringFrom(value),
                key: JSEngine.stringFrom(keyValue),
                transformation: JSEngine.stringFrom(transformationValue),
                iv: JSEngine.stringFrom(ivValue),
                defaultTransformation: "AES/ECB/PKCS5Padding"
            )
        }
        java.setObject(aesEncode, forKeyedSubscript: "aesEncodeToBase64String" as NSString)

        // aesBase64DecodeToByteArray(data, key, "AES/CBC/PKCS5Padding", iv) -> byte[]
        let aesDecodeBytes: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> JSValue = { [weak self] value, keyValue, transformationValue, ivValue in
            guard let context = self?.context else { return JSValue() }
            let text = JSEngine.stringFrom(value)
            let key = JSEngine.stringFrom(keyValue)
            let transformation = JSEngine.stringFrom(transformationValue)
            let iv = JSEngine.stringFrom(ivValue)
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
                  let decrypted = CryptoHelper.decrypt(
                    data,
                    key: Data(key.utf8),
                    iv: iv.isEmpty ? nil : Data(iv.utf8),
                    transformation: transformation.isEmpty ? "AES/CBC/PKCS5Padding" : transformation,
                    padding: true
                  ) else { return JSEngine.jsBytes(Data(), in: context) }
            return JSEngine.jsBytes(decrypted, in: context)
        }
        java.setObject(aesDecodeBytes, forKeyedSubscript: "aesBase64DecodeToByteArray" as NSString)

        // aesDecodeArgsBase64Str(data, key, "CBC", "PKCS7Padding", iv) -> String
        let aesDecodeArgs: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> String = { value, keyValue, modeValue, paddingValue, ivValue in
            let text = JSEngine.stringFrom(value)
            let key = JSEngine.stringFrom(keyValue)
            let mode = JSEngine.stringFrom(modeValue).uppercased()
            let padding = JSEngine.stringFrom(paddingValue)
            let iv = JSEngine.stringFrom(ivValue)
            let transformation = "AES/" + (mode.isEmpty ? "CBC" : mode) + "/"
                + (padding.isEmpty ? "PKCS7Padding" : padding)
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
                  let decrypted = CryptoHelper.decrypt(
                    data, key: Data(key.utf8),
                    iv: iv.isEmpty ? nil : Data(iv.utf8),
                    transformation: transformation, padding: true
                  ) else { return "" }
            return String(data: decrypted, encoding: .utf8) ?? JSEngine.cleanDecryptedString(decrypted)
        }
        java.setObject(aesDecodeArgs, forKeyedSubscript: "aesDecodeArgsBase64Str" as NSString)
    }
    // MARK: - 浏览器 / 视频 / 图片

    /// 网络类补齐：几个「名字不同、语义等价于 ajax」的入口。
    ///
    /// 这些调用点少但都是**裸调用**（不在 try 里），缺一个就是
    /// `undefined is not a function`，同一条 @js 规则后面的代码全部不执行。
    /// 实测：java.toURL 95 个源、java.aJax 3 个、java.postForm 1 个、
    /// java.fetch 1 个、java.addBook 11 个、java.setClipboard 2 个。
    private func installCompatNetwork(_ java: JSValue) {
        // java.toURL(url, base)：返回带 origin / pathname 等字段的 URL 对象。
        // 书源写 java.toURL(host,"").origin 做域名合法性校验。
        let toURL: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] urlValue, baseValue in
            guard let context = self?.context else { return JSValue() }
            let raw = JSEngine.stringFrom(urlValue)
            let base = JSEngine.stringFrom(baseValue)
            let resolved = RuleUtil.absoluteURL(raw, base: base.isEmpty ? self?.host.baseUrl : base)
            // 对齐 Java 的 `new URL(...)`：必须有协议，http(s) 还必须有主机。
            // 只判 `URL(string:) != nil` 不够 —— Swift 认为 "abc" 这种相对串
            // 也是合法 URL，源里的 try/catch 兜底就永远不会命中。
            //
            // 解析失败时返回 **null**，让脚本自己捕获：
            // `java.toURL(x).origin` 对 null 取属性会抛真正的 TypeError，
            // 正好落进书源普遍写的 try{…}catch(e){ 提示不是有效链接 }。
            // 反过来在回调里写 context.exception 会污染整次求值的异常状态 ——
            // 即便脚本 catch 住了，evaluateOnQueue 也会当成整条规则失败。
            let schemesNeedingHost = ["http", "https", "ftp", "ws", "wss"]
            guard let components = URLComponents(string: resolved),
                  let scheme = components.scheme, !scheme.isEmpty,
                  let url = components.url,
                  !(schemesNeedingHost.contains(scheme.lowercased()) && (url.host ?? "").isEmpty) else {
                return JSValue(nullIn: context)
            }
            let object = JSEngine.newObject(in: context)
            let host = url.host ?? ""
            let port = url.port.map { ":\($0)" } ?? ""
            let path = url.path.isEmpty ? "/" : url.path
            object.setObject(scheme.isEmpty ? "" : scheme + ":", forKeyedSubscript: "protocol" as NSString)
            object.setObject(host, forKeyedSubscript: "host" as NSString)
            object.setObject(host, forKeyedSubscript: "hostname" as NSString)
            object.setObject(url.port ?? 0, forKeyedSubscript: "port" as NSString)
            object.setObject(scheme + "://" + host + port, forKeyedSubscript: "origin" as NSString)
            object.setObject(path, forKeyedSubscript: "pathname" as NSString)
            object.setObject(url.query ?? "", forKeyedSubscript: "search" as NSString)
            object.setObject(url.fragment ?? "", forKeyedSubscript: "hash" as NSString)
            object.setObject(resolved, forKeyedSubscript: "href" as NSString)
            let toString: @convention(block) () -> String = { resolved }
            object.setObject(toString, forKeyedSubscript: "toString" as NSString)
            return object
        }
        java.setObject(toURL, forKeyedSubscript: "toURL" as NSString)

        // java.aJax(url)：老式异步请求，返回**响应体文本**（不是响应对象）。
        // 书源写 JSON.parse(java.aJax(url))，所以必须直接给字符串。
        let aJax: @convention(block) (JSValue, JSValue, JSValue) -> String = { [weak self] urlValue, headerValue, _ in
            guard let self else { return "" }
            let target = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return "" }
            let response = self.connect(url: target, header: headerValue, method: nil, body: nil)
            return response.objectForKeyedSubscript("__text")?.toString() ?? ""
        }
        java.setObject(aJax, forKeyedSubscript: "aJax" as NSString)
        java.setObject(aJax, forKeyedSubscript: "ajaxAwait" as NSString)

        // java.postForm(url, body, header?)：表单 POST，返回响应体文本。
        let postForm: @convention(block) (JSValue, JSValue, JSValue) -> String = { [weak self] urlValue, bodyValue, headerValue in
            guard let self else { return "" }
            let target = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return "" }
            var headers = headerValue
            if headers.isUndefined || headers.isNull {
                if let context = self.context {
                    headers = JSValue(object: ["Content-Type": "application/x-www-form-urlencoded"], in: context) ?? JSValue()
                }
            }
            let response = self.connect(
                url: target,
                header: headers,
                method: "POST",
                body: JSEngine.stringFrom(bodyValue)
            )
            return response.objectForKeyedSubscript("__text")?.toString() ?? ""
        }
        java.setObject(postForm, forKeyedSubscript: "postForm" as NSString)
        java.setObject(postForm, forKeyedSubscript: "postAwait" as NSString)

        // java.fetch(url, options)：返回带 body() / headers() 的响应对象
        // —— 与 java.connect 同形（书源写 …fetch(url,{…}).body().string()）。
        let fetch: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] urlValue, optionsValue in
            guard let self else { return JSValue() }
            let target = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return JSValue() }
            var method: String?
            var body: String?
            var headers = JSValue()
            if let dictionary = JSEngine.dictionaryFrom(optionsValue) {
                if let value = dictionary["method"] { method = (RuleUtil.asString(value) ?? "").uppercased() }
                if let value = dictionary["body"] { body = RuleUtil.asString(value) }
                headers = optionsValue.objectForKeyedSubscript("headers")
            }
            return self.connect(url: target, header: headers, method: method, body: body)
        }
        java.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }

    /// 浏览器与媒体类 API。
    ///
    /// showReadingBrowser / startBrowserDp 是段评（章节内联评论）入口：
    /// 书源在正文里插 <comment onPress="java.showReadingBrowser(...)">，
    /// 点击才触发，不在求值主路径上，做成转发即可。
    private func installCompatBrowser(_ java: JSValue) {
        let openBrowser: @convention(block) (JSValue, JSValue) -> Void = { [weak self] urlValue, titleValue in
            let url = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            _ = self?.waitForUserAction(url: url, title: JSEngine.stringFrom(titleValue))
        }
        for name in ["showReadingBrowser", "startBrowserDp", "openWeb", "openBook"] {
            java.setObject(openBrowser, forKeyedSubscript: name as NSString)
        }

        // java.openVideoPlayer(url, title, float?)：把直链交给界面播放。
        let openVideo: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] urlValue, titleValue, _ in
            let url = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            self?.onOpenVideo?(url, JSEngine.stringFrom(titleValue))
        }
        java.setObject(openVideo, forKeyedSubscript: "openVideoPlayer" as NSString)

        // java.showPhoto(url)：点开大图，转发为一次浏览器打开。
        let showPhoto: @convention(block) (JSValue) -> Void = { [weak self] value in
            let url = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            _ = self?.waitForUserAction(url: url, title: "")
        }
        java.setObject(showPhoto, forKeyedSubscript: "showPhoto" as NSString)
    }
    // MARK: - 其余

    private func installCompatMisc(_ java: JSValue) {
        // java.upLoginData(map)：保存登录表单里填的账号 / 密码。
        //
        // 三种调用形态都要接受：无参（表示「要求重新登录」）、
        // 对象字面量、以及 Packages.java.util.HashMap（75 个源依赖）。
        let upLoginData: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            guard !value.isUndefined, !value.isNull else {
                self.onRequestLogin?()
                return
            }
            var info = self.loginInfo
            if let dictionary = JSEngine.dictionaryFrom(value) {
                for (key, item) in dictionary { info[key] = RuleUtil.asString(item) ?? "" }
            } else if let dictionary = JSEngine.stringFrom(value).jsonObject as? [String: Any] {
                for (key, item) in dictionary { info[key] = RuleUtil.asString(item) ?? "" }
            }
            self.loginInfo = info
            self.onLoginInfoChanged?(info)
        }
        java.setObject(upLoginData, forKeyedSubscript: "upLoginData" as NSString)

        // java.reLoginView()：脚本要求重新弹出登录界面。
        let reLogin: @convention(block) () -> Void = { [weak self] in
            self?.onRequestLogin?()
        }
        java.setObject(reLogin, forKeyedSubscript: "reLoginView" as NSString)

        // java.ruleUrl / java.redirectUrl：属性形式（不是方法），
        // 书源写成 baseUrl + java.ruleUrl、if (baseUrl != java.redirectUrl)。
        //
        // 必须是**实时**取值：host.baseUrl 在一次阅读里会被反复改写
        // （每请求一个页面就更新一次），setup 时快照下来的话，
        // 后续规则读到的永远是书源入口地址。
        if let context {
            for name in ["ruleUrl", "baseUrl"] {
                JSEngine.defineProperty(name, descriptor: JSEngine.propertyDescriptor(
                    get: { [weak self] in
                        guard let self, let context = self.context else { return JSValue() }
                        return JSValue(object: self.host.baseUrl, in: context)
                    },
                    set: { [weak self] value in
                        let text = JSEngine.stringFrom(value)
                        if !text.isEmpty { self?.host.baseUrl = text }
                    },
                    in: context
                ), on: java, in: context)
            }
            // java.redirectUrl：最后一次请求的真实地址（书源写
            // `if (baseUrl != java.redirectUrl) { 重新设置书籍地址 }`）。
            // 拿不到响应时退回当前 baseUrl，保证两边不等号判断不会误触发。
            JSEngine.defineProperty("redirectUrl", descriptor: JSEngine.propertyDescriptor(
                get: { [weak self] in
                    guard let self, let context = self.context else { return JSValue() }
                    let final = self.lastResponse?.finalURL?.absoluteString
                    return JSValue(object: final ?? self.host.baseUrl, in: context)
                },
                set: { [weak self] value in
                    let text = JSEngine.stringFrom(value)
                    if !text.isEmpty { self?.host.baseUrl = text }
                },
                in: context
            ), on: java, in: context)
        }

        // java.initUrl()：重置「当前地址」到书源入口。
        let initUrl: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            if !self.host.sourceUrl.isEmpty { self.host.baseUrl = self.host.sourceUrl }
        }
        java.setObject(initUrl, forKeyedSubscript: "initUrl" as NSString)

        // java.getResponse()：本次请求的响应对象。
        let getResponse: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context,
                  let response = self.lastResponse else { return JSValue() }
            return self.makeResponseObject(response, context: context)
        }
        java.setObject(getResponse, forKeyedSubscript: "getResponse" as NSString)

        // java.getHeaderMap()：请求头，按 java.util.Map 语义返回。
        let getHeaderMap: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context else { return JSValue() }
            let wrap = context.objectForKeyedSubscript("__dxWrapMap")
            // 有响应时优先给**响应头**：书源写
            // `source.getHeaderMap(true).get("User-Agent")` 做 UA 自检，
            // 用请求头会让它永远看到自己配置的那个值，自检形同虚设。
            var headers = self.lastResponse?.headers ?? [:]
            if headers.isEmpty { headers = self.host.headers }
            guard let wrap, !wrap.isUndefined,
                  let raw = JSValue(object: headers, in: context),
                  let mapped = wrap.call(withArguments: [raw]) else { return JSValue() }
            return mapped
        }
        java.setObject(getHeaderMap, forKeyedSubscript: "getHeaderMap" as NSString)

        // java.webViewGetOverrideUrl(html, host, path, pattern)：抓「被 WebView
        // 拦截的跳转地址」。无真实 WebView 时退化为在给定 HTML 里按 pattern
        // 找第一个匹配的 URL，够 pixiv 这类源用。
        let overrideUrl: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { htmlValue, hostValue, _, patternValue in
            let html = JSEngine.stringFrom(htmlValue)
            let host = JSEngine.stringFrom(hostValue)
            let pattern = JSEngine.stringFrom(patternValue)
            guard !html.isEmpty else { return "" }
            let probe = pattern.isEmpty ? "https?://[^\"'\\s<>]+" : pattern
            for match in RuleUtil.regexMatch(html, pattern: probe) where !match.isEmpty {
                if match.lowercased().hasPrefix("http") { return match }
                if !host.isEmpty { return host + match }
                return match
            }
            return ""
        }
        java.setObject(overrideUrl, forKeyedSubscript: "webViewGetOverrideUrl" as NSString)

        // java.logType(x)：带类型的调试输出。
        let logType: @convention(block) (JSValue) -> Void = { value in
            let text = JSEngine.stringFrom(value)
            Log.debugLog("JS", "logType: " + String(text.prefix(200)))
        }
        java.setObject(logType, forKeyedSubscript: "logType" as NSString)

        // java.vibrate(ms) / java.apk(...)：环境探针。
        //
        // 新版 5872 个订阅源里只有这两个 java.* 名字还没注册，且都是
        // `if (typeof java !== 'undefined' && java.vibrate) { java.vibrate(ms); return; }`
        // 这种**特性探测**写法 —— 缺失本身不报错，但探测失败会让脚本继续往下
        // 去找 Android.* 分支，最终整段 return 不到预期位置。
        // apk 的调用点更特殊：它出现在「蓝奏云盘」的说明文案里
        // （…/release/leanback-java.apk【】…），只是被扫描器当成调用点，
        // 注册成空实现即可，不影响任何逻辑。
        let vibrate: @convention(block) (JSValue) -> Void = { _ in }
        java.setObject(vibrate, forKeyedSubscript: "vibrate" as NSString)
        let apk: @convention(block) (JSValue) -> Void = { _ in }
        java.setObject(apk, forKeyedSubscript: "apk" as NSString)

        // java.putSharedData(key, value)：跨规则共享数据。
        let putSharedData: @convention(block) (JSValue, JSValue) -> Void = { [weak self] keyValue, valueValue in
            let key = JSEngine.stringFrom(keyValue)
            guard !key.isEmpty else { return }
            self?.cache["shared:" + key] = JSEngine.stringFrom(valueValue)
        }
        java.setObject(putSharedData, forKeyedSubscript: "putSharedData" as NSString)

        // 主题 / 阅读配置：段评气泡配色会读它，给一组安全默认值。
        let themeMap: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context else { return JSValue() }
            let wrap = context.objectForKeyedSubscript("__dxWrapMap")
            let values: [String: String] = [
                "isNightTheme": "false",
                "textColor": "ff000000",
                "textColorNight": "ffcccccc"
            ]
            guard let wrap, !wrap.isUndefined,
                  let raw = JSValue(object: values, in: context),
                  let mapped = wrap.call(withArguments: [raw]) else { return JSValue() }
            return mapped
        }
        java.setObject(themeMap, forKeyedSubscript: "getReadBookConfigMap" as NSString)
        java.setObject(themeMap, forKeyedSubscript: "getThemeConfigMap" as NSString)
        java.setObject(themeMap, forKeyedSubscript: "getThemeConfig" as NSString)

        // java.readBookConfig：存在性探测型字段（源里写
        // if (typeof java.readBookConfig == "undefined") { 提示升级 }），
        // 因此注册成空串而不是对象 —— 对象会让源误判版本。
        java.setObject("", forKeyedSubscript: "readBookConfig" as NSString)

        // java.clearCookie(url)：清掉当前书源的 cookie。
        let clearCookie: @convention(block) (JSValue) -> Void = { [weak self] _ in
            guard let self else { return }
            CookieJar.shared.clear(sourceKey: self.host.sourceKey)
        }
        java.setObject(clearCookie, forKeyedSubscript: "clearCookie" as NSString)

        // java.urlEncode(text)：对中文 / 空格做百分号编码。
        let urlEncode: @convention(block) (JSValue) -> String = { value in
            JSEngine.stringFrom(value)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        java.setObject(urlEncode, forKeyedSubscript: "urlEncode" as NSString)

        // java.toString(x)：返回对象的字符串形态。
        //
        // 书源写 `java.toString(result)` 把 jsoup 元素取成 HTML 文本再正则
        // （实测 2 处），而 JS 侧 `String(result)` 对元素对象只会得到
        // "[object Object]"。这里按 Legado 语义返回节点 / 内容的 HTML 文本。
        let toString: @convention(block) (JSValue) -> String = { value in
            if value.isUndefined { return "" }
            if value.isNull { return "null" }
            if value.isString { return value.toString() ?? "" }
            // 元素对象：取 outerHTML（书源拿它做正则匹配）
            if let html = value.objectForKeyedSubscript("outerHtml"), !html.isUndefined {
                let text = html.toString() ?? ""
                if !text.isEmpty { return text }
            }
            if let text = value.objectForKeyedSubscript("outerHTML")?.toString(), !text.isEmpty { return text }
            if let text = value.objectForKeyedSubscript("text")?.toString(), !text.isEmpty { return text }
            return value.toString() ?? ""
        }
        java.setObject(toString, forKeyedSubscript: "toString" as NSString)

        // java.addBook(url)：把地址交给宿主加入书架（11 个源用于「跳转书籍」）。
        let addBook: @convention(block) (JSValue) -> Void = { [weak self] value in
            let url = JSEngine.stringFrom(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            self?.host.onAddBook?(url)
        }
        java.setObject(addBook, forKeyedSubscript: "addBook" as NSString)

        // java.setClipboard(text)：把诊断文本写进剪贴板（2 个源）。
        let setClipboard: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.host.onClipboard?(JSEngine.stringFrom(value))
        }
        java.setObject(setClipboard, forKeyedSubscript: "setClipboard" as NSString)

        // java.startBrowserAwaitAwait(url, title)：Legado 的「等待浏览器返回」入口。
        // 与 startBrowserAwait 同义，直接复用宿主弹窗桥接。
        let startBrowserAwaitAwait: @convention(block) (JSValue, JSValue) -> String = { [weak self] urlValue, titleValue in
            guard let self else { return "" }
            let url = JSEngine.stringFrom(urlValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return "" }
            return self.waitForUserAction(url: url, title: JSEngine.stringFrom(titleValue))
        }
        java.setObject(startBrowserAwaitAwait, forKeyedSubscript: "startBrowserAwaitAwait" as NSString)

        // java.ocr(...)：OCR 能力探测点（源里写 typeof java.ocr === "function"）。
        //
        // **故意不注册** —— 见 installCompatDevice 对 java.qread 的说明：
        // 书源用它区分「阅读 T 版」并据此走不同接口，注册了会走错分支。
    }

    // MARK: - 辅助

    /// 加密工具：把 data 用 key/iv/transformation 加密后转 base64。
    static func compatEncrypt(
        data: String,
        key: String,
        transformation: String,
        iv: String,
        defaultTransformation: String
    ) -> String {
        let algorithm = transformation.isEmpty ? defaultTransformation : transformation
        guard let encrypted = CryptoHelper.encrypt(
            Data(data.utf8),
            key: Data(key.utf8),
            iv: iv.isEmpty ? nil : Data(iv.utf8),
            transformation: algorithm,
            padding: true
        ) else { return "" }
        return encrypted.base64EncodedString()
    }

    /// 取原始字节用于 ZIP 解析（不能走字符串通路，会被当成文本解码破坏二进制）。
    private func fetchZipData(url: String) -> Data? {
        let lowered = url.lowercased()
        guard lowered.contains(".zip") || lowered.contains("zip=") else { return nil }
        let (finalURL, parsed) = HTTPClient.parseURLRule(url)
        var options = parsed
        if options.method.isEmpty { options.method = "GET" }
        let resolved = RuleUtil.absoluteURL(finalURL, base: host.baseUrl)
        guard !resolved.isEmpty else { return nil }
        return try? HTTPClient.shared.requestSync(
            urlString: resolved,
            options: options,
            sourceKey: host.sourceKey,
            defaultHeaders: host.headers
        ).data
    }
}
