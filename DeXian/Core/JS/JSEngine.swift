import Foundation
import CoreFoundation
import JavaScriptCore
import CryptoKit

/// 书源 JavaScript 运行时。
///
/// 对齐 Legado 的 Rhino 环境：暴露 java / source / book / chapter / cookie / cache
/// 以及 result / baseUrl / src / title / key / page 等变量。
/// JavaScriptCore 不是线程安全的，这里用递归锁串行化访问。
final class JSEngine {

    /// 宿主回调：把规则求值能力交回给规则引擎（java.getString 等）
    struct Host {
        var sourceKey: String = ""
        var sourceName: String = ""
        var baseUrl: String = ""
        var headers: [String: String] = [:]
        var resolveString: ((String, Any?, Bool) -> String)?
        var resolveStringList: ((String, Any?, Bool) -> [String])?
        var setContent: ((Any?) -> Void)?
        var document: HTMLNode?
        var bookInfo: [String: String] = [:]
        var chapterInfo: [String: String] = [:]
        var title: String = ""
        /// 跨步骤共享的书籍级变量
        var variables = VariableStore()
    }

    let context: JSContext?
    private let lock = NSRecursiveLock()

    private var sourceVariable: String = ""
    private var loginHeader: String?
    private var loginInfo: [String: String] = [:]
    private var cache: [String: String] = [:]

    var host: Host
    var key: String = ""
    var page: Int = 1
    var result: Any?
    var src: String = ""

    /// 每个引擎一个虚拟机，但**必须能被释放**。
    ///
    /// 之前这里存在一个强引用环：注册给 JS 的每个 block 都强捕获了
    /// JSContext，而这些 block 又存在同一个 JSContext 的全局对象上
    /// （java / source / cache …），于是
    /// `JSContext → java → block → JSContext` 自锁，JSContext 永不释放，
    /// 连带它持有的 JSVirtualMachine 也永不释放。
    /// 搜索每跑一个书源就泄漏一整个虚拟机，搜到近百个源时
    /// JavaScriptCore 内存分配失败走 CRASH() → abort，
    /// 表现为 SIGABRT、调用栈全是 JavaScriptCore 帧，
    /// 且稳定地「搜到某个数量就闪退」。
    /// 现在所有 block 一律 [weak context] 捕获，环被打断，
    /// 引擎随书源任务结束即时释放（在飞的最多 concurrentLimit 个）。

    init(host: Host = Host()) {
        self.host = host
        context = JSContext(virtualMachine: JSVirtualMachine())
        setup()
    }

    // MARK: 求值

    /// 求值脚本。返回 String / Int64 / Double / Bool / JSON 对象。
    /// JS 求值专用线程。
    ///
    /// 书源脚本里会有 `java.ajax` 这类同步网络调用，必须在求值期间阻塞。
    /// 如果直接在 Swift 并发协作线程池上求值，阻塞会占满池线程
    /// （iPhone 通常只有 6 个左右），后续 Task 拿不到线程就会整页卡死，
    /// 最终被系统看门狗强杀。这里统一把求值放到专用线程串行执行。
    /// 用 specific 标记队列身份：脚本内部会回调 java.getString，
    /// 进而重入 evaluate。若直接对串行队列 sync 会自锁死，这里做可重入判断。
    private static let evaluationQueueKey = DispatchSpecificKey<UInt8>()
    private static let evaluationQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.dexian.js.evaluate", attributes: .concurrent)
        queue.setSpecific(key: evaluationQueueKey, value: 1)
        return queue
    }()

    /// 供需要「等待用户操作」的脚本调用（如 java.startBrowserAwait）。
    /// 由外部注入：运行在后台线程，内部自行切主线程弹出界面。
    var awaitUserAction: ((String, String) -> String)?

    /// 在 JS 求值内部同步等待用户完成网页操作（验证码 / 登录）。
    ///
    /// 脚本运行在专用线程上，这里用信号量阻塞不会影响协作线程池。
    func waitForUserAction(url: String, title: String) -> String {
        guard let awaitUserAction else { return "" }
        return awaitUserAction(url, title)
    }

    func evaluate(_ script: String) -> Any? {
        // 已在专用线程上（脚本回调重入）：直接求值，避免对同一队列 sync 死锁
        if DispatchQueue.getSpecific(key: JSEngine.evaluationQueueKey) != nil {
            return evaluateOnQueue(script)
        }
        var output: Any?
        JSEngine.evaluationQueue.sync {
            output = evaluateOnQueue(script)
        }
        return output
    }

    private func evaluateOnQueue(_ script: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return nil }

        // 每次求值都在独立的 autorelease pool 里跑。
        //
        // JavaScriptCore 的 JSValue / 异常对象都是 autorelease 的 Objective-C 对象：
        // 一次搜索要跑上百个书源、每个源评估几十条规则，产生的临时对象以万计。
        // Swift 并发任务跑在协作线程池上，**不自带 autorelease pool**，
        // 这些临时对象会一直挂在线程上直到线程被回收 ——
        // 表现就是搜索越跑内存越高，到某个固定数量后进程被系统一次性清掉。
        // 求值返回值经 swiftValue 已转成纯 Swift 类型（String / Int64 / Array / Dictionary），
        // 不依赖 pool 存活，因此在池内返回是安全的。
        return autoreleasepool {
            context.setObject(key, forKeyedSubscript: "key" as NSString)
            context.setObject(page, forKeyedSubscript: "page" as NSString)
            context.setObject(host.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
            context.setObject(src, forKeyedSubscript: "src" as NSString)
            context.setObject(host.title, forKeyedSubscript: "title" as NSString)
            if let result {
                // result 可能是 HTMLNode（pure Swift class）或含它的容器：
                // 直接交给 JavaScriptCore 会在 ObjC 桥接层反射它的内存布局，
                // 触发 Swift 运行时陷阱（SIGABRT）。必须先净化为 JSC 认识的形态。
                context.setObject(JSEngine.jsSafeValue(result), forKeyedSubscript: "result" as NSString)
            }

            let value = context.evaluateScript(script)
            if let exception = context.exception {
                let message = exception.toString() ?? ""
                Log.debugLog("JS", "异常: " + message + " | 脚本: " + String(script.prefix(160)))
                context.exception = nil
                return nil
            }
            return JSEngine.swiftValue(value)
        }
    }

    func evaluateString(_ script: String) -> String {
        RuleUtil.asString(evaluate(script)) ?? ""
    }

    /// 规则引擎读写书籍级变量
    func variable(named name: String) -> String? {
        host.variables[name]
    }

    func setVariable(_ name: String, value: String) {
        host.variables[name] = value
    }

    /// 注入 jsLib（支持代码片段；URL 形式在当前版本忽略）
    func loadJsLib(_ jsLib: String) {
        let trimmed = jsLib.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return }
        _ = evaluate(trimmed)
    }

    // MARK: 环境搭建

    private func setup() {
        guard let context else { return }
        context.exceptionHandler = { _, exception in
            Log.debugLog("JS", "未捕获异常: " + (exception?.toString() ?? ""))
        }
        setupJava(context)
        setupSource(context)
        setupBookChapter(context)
        setupCookie(context)
        setupCache(context)
        _ = context.evaluateScript("var console = { log: function(){ java.log(Array.prototype.join.call(arguments,' ')) } };")
    }

    private func setupJava(_ context: JSContext) {
        let java = JSEngine.newObject(in: context)

        let connect: @convention(block) (JSValue) -> JSValue = { [weak self, weak context] urlValue in
            guard let self else { return JSValue(undefinedIn: context) }
            return self.connect(url: JSEngine.stringFrom(urlValue), header: nil, method: nil, body: nil)
        }
        java.setObject(connect, forKeyedSubscript: "connect" as NSString)

        let ajax: @convention(block) (JSValue) -> String = { [weak self] urlValue in
            guard let self else { return "" }
            let response = self.connect(url: JSEngine.stringFrom(urlValue), header: nil, method: nil, body: nil)
            return response.objectForKeyedSubscript("__text")?.toString() ?? ""
        }
        java.setObject(ajax, forKeyedSubscript: "ajax" as NSString)

        let get: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self, weak context] urlValue, headerValue in
            guard let self else { return JSValue(undefinedIn: context) }
            return self.connect(url: JSEngine.stringFrom(urlValue), header: headerValue, method: "GET", body: nil)
        }
        java.setObject(get, forKeyedSubscript: "get" as NSString)

        let post: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self, weak context] urlValue, bodyValue, headerValue in
            guard let self else { return JSValue(undefinedIn: context) }
            return self.connect(url: JSEngine.stringFrom(urlValue),
                                header: headerValue,
                                method: "POST",
                                body: JSEngine.stringFrom(bodyValue))
        }
        java.setObject(post, forKeyedSubscript: "post" as NSString)

        let log: @convention(block) (JSValue) -> Void = { value in
            Log.debugLog("JS", JSEngine.stringFrom(value))
        }
        java.setObject(log, forKeyedSubscript: "log" as NSString)

        // 对应 Legado 的 java.startBrowserAwait：弹出网页让用户过验证 / 登录，
        // 完成后把 Cookie 交回脚本继续执行。
        let startBrowserAwait: @convention(block) (JSValue, JSValue) -> String = { [weak self] urlValue, titleValue in
            guard let self else { return "" }
            let target = JSEngine.stringFrom(urlValue)
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            let title = JSEngine.stringFrom(titleValue)
            return self.waitForUserAction(url: target, title: title)
        }
        java.setObject(startBrowserAwait, forKeyedSubscript: "startBrowserAwait" as NSString)

        let startBrowser: @convention(block) (JSValue, JSValue) -> Void = { [weak self] urlValue, titleValue in
            guard let self else { return }
            let target = JSEngine.stringFrom(urlValue)
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = self.waitForUserAction(url: target, title: JSEngine.stringFrom(titleValue))
        }
        java.setObject(startBrowser, forKeyedSubscript: "startBrowser" as NSString)

        let getVariable: @convention(block) (String) -> String? = { [weak self] name in
            self?.host.variables[name]
        }
        java.setObject(getVariable, forKeyedSubscript: "get" as NSString)

        let putVariable: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.host.variables[name] = JSEngine.stringFrom(value)
        }
        java.setObject(putVariable, forKeyedSubscript: "put" as NSString)

        let md5: @convention(block) (JSValue) -> String = { value in
            Crypto.md5(JSEngine.stringFrom(value))
        }
        java.setObject(md5, forKeyedSubscript: "md5Encode" as NSString)

        let md516: @convention(block) (JSValue) -> String = { value in
            String(Crypto.md5(JSEngine.stringFrom(value)).prefix(16))
        }
        java.setObject(md516, forKeyedSubscript: "md5Encode16" as NSString)

        let base64Encode: @convention(block) (JSValue) -> String = { value in
            Data(JSEngine.stringFrom(value).utf8).base64EncodedString()
        }
        java.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)

        let base64Decode: @convention(block) (JSValue) -> String = { value in
            let text = JSEngine.stringFrom(value)
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        java.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)

        let hexEncode: @convention(block) (JSValue) -> String = { value in
            Data(JSEngine.stringFrom(value).utf8).map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(hexEncode, forKeyedSubscript: "hexEncode" as NSString)

        let hexDecode: @convention(block) (JSValue) -> String = { value in
            let text = JSEngine.stringFrom(value)
            var bytes: [UInt8] = []
            var index = text.startIndex
            while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
                if let byte = UInt8(text[index..<next], radix: 16) { bytes.append(byte) }
                index = next
            }
            return String(data: Data(bytes), encoding: .utf8) ?? ""
        }
        java.setObject(hexDecode, forKeyedSubscript: "hexDecode" as NSString)

        let digestHex: @convention(block) (JSValue, JSValue) -> String = { data, algorithm in
            Crypto.digestHex(JSEngine.stringFrom(data), algorithm: JSEngine.stringFrom(algorithm))
        }
        java.setObject(digestHex, forKeyedSubscript: "digestHex" as NSString)

        let hmacHex: @convention(block) (JSValue, JSValue, JSValue) -> String = { data, algorithm, keyValue in
            Crypto.hmacHex(JSEngine.stringFrom(data),
                           algorithm: JSEngine.stringFrom(algorithm),
                           key: JSEngine.stringFrom(keyValue))
        }
        java.setObject(hmacHex, forKeyedSubscript: "HMacHex" as NSString)

        let getString: @convention(block) (String, JSValue, Bool) -> String = { [weak self] rule, content, isURL in
            guard let self else { return "" }
            let target: Any? = (content.isUndefined || content.isNull) ? nil : JSEngine.swiftValue(content)
            return self.host.resolveString?(rule, target, isURL) ?? ""
        }
        java.setObject(getString, forKeyedSubscript: "getString" as NSString)

        let getStringList: @convention(block) (String, JSValue, Bool) -> [String] = { [weak self] rule, content, isURL in
            guard let self else { return [] }
            let target: Any? = (content.isUndefined || content.isNull) ? nil : JSEngine.swiftValue(content)
            return self.host.resolveStringList?(rule, target, isURL) ?? []
        }
        java.setObject(getStringList, forKeyedSubscript: "getStringList" as NSString)

        let setContent: @convention(block) (JSValue) -> Void = { [weak self] content in
            let value: Any? = (content.isUndefined || content.isNull) ? nil : JSEngine.swiftValue(content)
            self?.host.setContent?(value)
        }
        java.setObject(setContent, forKeyedSubscript: "setContent" as NSString)

        let getElement: @convention(block) (String) -> JSValue = { [weak self, weak context] rule in
            guard let self, let document = self.currentDocument() else { return JSValue(undefinedIn: context) }
            guard let first = self.selectNodes(rule, in: document).first else {
                return JSValue(undefinedIn: context)
            }
            return self.wrapElement(first)
        }
        java.setObject(getElement, forKeyedSubscript: "getElement" as NSString)

        let getElements: @convention(block) (String) -> [JSValue] = { [weak self] rule in
            guard let self, let document = self.currentDocument() else { return [] }
            return self.selectNodes(rule, in: document).map { self.wrapElement($0) }
        }
        java.setObject(getElements, forKeyedSubscript: "getElements" as NSString)

        let openUrl: @convention(block) (String) -> Void = { url in
            Log.debugLog("JS", "openUrl: " + url)
        }
        java.setObject(openUrl, forKeyedSubscript: "openUrl" as NSString)

        let timeFormat: @convention(block) (JSValue, JSValue) -> String = { time, format in
            let timestamp = RuleUtil.asDouble(JSEngine.swiftValue(time)) ?? Date().timeIntervalSince1970
            let seconds = timestamp > 1e12 ? timestamp / 1000 : timestamp
            var pattern = JSEngine.stringFrom(format)
            if pattern.isEmpty { pattern = "yyyy-MM-dd HH:mm" }
            pattern = pattern.replacingOccurrences(of: "YYYY", with: "yyyy")
            pattern = pattern.replacingOccurrences(of: "DD", with: "dd")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = pattern
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        java.setObject(timeFormat, forKeyedSubscript: "timeFormat" as NSString)

        let queryTTF: @convention(block) (JSValue) -> JSValue = { [weak context] _ in
            JSValue(undefinedIn: context)
        }
        java.setObject(queryTTF, forKeyedSubscript: "queryTTF" as NSString)

        let replaceFont: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { text, _, _, _ in
            JSEngine.stringFrom(text)
        }
        java.setObject(replaceFont, forKeyedSubscript: "replaceFont" as NSString)

        java.setObject(host.baseUrl, forKeyedSubscript: "url" as NSString)
        java.setObject(host.headers, forKeyedSubscript: "headerMap" as NSString)

        context.setObject(java, forKeyedSubscript: "java" as NSString)
        _ = context.evaluateScript("var Packages = { java: java }; var JavaImporter = function(){};")
    }

    private func setupSource(_ context: JSContext) {
        let source = JSEngine.newObject(in: context)

        let getKey: @convention(block) () -> String = { [weak self] in self?.host.sourceKey ?? "" }
        source.setObject(getKey, forKeyedSubscript: "getKey" as NSString)

        let getVariable: @convention(block) () -> String? = { [weak self] in
            guard let value = self?.sourceVariable, !value.isEmpty else { return nil }
            return value
        }
        source.setObject(getVariable, forKeyedSubscript: "getVariable" as NSString)

        let setVariable: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.sourceVariable = JSEngine.stringFrom(value)
        }
        source.setObject(setVariable, forKeyedSubscript: "setVariable" as NSString)

        let getLoginHeader: @convention(block) () -> String? = { [weak self] in self?.loginHeader }
        source.setObject(getLoginHeader, forKeyedSubscript: "getLoginHeader" as NSString)

        let getLoginHeaderMap: @convention(block) () -> [String: String] = { [weak self] in
            guard let header = self?.loginHeader, let dictionary = header.jsonObject as? [String: Any] else { return [:] }
            var result: [String: String] = [:]
            for (key, value) in dictionary { result[key] = RuleUtil.asString(value) ?? "" }
            return result
        }
        source.setObject(getLoginHeaderMap, forKeyedSubscript: "getLoginHeaderMap" as NSString)

        let putLoginHeader: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.loginHeader = JSEngine.stringFrom(value)
        }
        source.setObject(putLoginHeader, forKeyedSubscript: "putLoginHeader" as NSString)

        let removeLoginHeader: @convention(block) () -> Void = { [weak self] in
            self?.loginHeader = nil
        }
        source.setObject(removeLoginHeader, forKeyedSubscript: "removeLoginHeader" as NSString)

        let getLoginInfo: @convention(block) () -> String? = { [weak self] in
            guard let info = self?.loginInfo, !info.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: info) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        source.setObject(getLoginInfo, forKeyedSubscript: "getLoginInfo" as NSString)

        let getLoginInfoMap: @convention(block) () -> [String: String] = { [weak self] in
            self?.loginInfo ?? [:]
        }
        source.setObject(getLoginInfoMap, forKeyedSubscript: "getLoginInfoMap" as NSString)

        let removeLoginInfo: @convention(block) () -> Void = { [weak self] in
            self?.loginInfo = [:]
        }
        source.setObject(removeLoginInfo, forKeyedSubscript: "removeLoginInfo" as NSString)

        let put: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.host.variables[name] = JSEngine.stringFrom(value)
        }
        source.setObject(put, forKeyedSubscript: "put" as NSString)

        let get: @convention(block) (String) -> String? = { [weak self] name in
            self?.host.variables[name]
        }
        source.setObject(get, forKeyedSubscript: "get" as NSString)

        context.setObject(source, forKeyedSubscript: "source" as NSString)
    }

    private func setupBookChapter(_ context: JSContext) {
        let book = JSEngine.newObject(in: context)
        for key in ["name", "author", "bookUrl", "tocUrl", "origin", "originName", "coverUrl", "intro", "kind"] {
            book.setObject(host.bookInfo[key] ?? "", forKeyedSubscript: key as NSString)
        }
        for (key, value) in host.bookInfo {
            book.setObject(value, forKeyedSubscript: key as NSString)
        }
        context.setObject(book, forKeyedSubscript: "book" as NSString)

        let chapter = JSEngine.newObject(in: context)
        chapter.setObject("", forKeyedSubscript: "title" as NSString)
        chapter.setObject("", forKeyedSubscript: "url" as NSString)
        chapter.setObject("", forKeyedSubscript: "baseUrl" as NSString)
        chapter.setObject("", forKeyedSubscript: "bookUrl" as NSString)
        chapter.setObject(0, forKeyedSubscript: "index" as NSString)
        for (key, value) in host.chapterInfo {
            chapter.setObject(value, forKeyedSubscript: key as NSString)
        }
        context.setObject(chapter, forKeyedSubscript: "chapter" as NSString)
    }

    private func setupCookie(_ context: JSContext) {
        let cookie = JSEngine.newObject(in: context)

        let getCookie: @convention(block) (String) -> String = { [weak self] urlString in
            guard let self, let url = URL(string: urlString) else { return "" }
            return CookieJar.shared.cookieHeader(for: self.host.sourceKey, url: url) ?? ""
        }
        cookie.setObject(getCookie, forKeyedSubscript: "getCookie" as NSString)

        let getKey: @convention(block) (String, String) -> String = { [weak self] urlString, name in
            guard let self, let url = URL(string: urlString),
                  let header = CookieJar.shared.cookieHeader(for: self.host.sourceKey, url: url) else { return "" }
            for pair in header.components(separatedBy: ";") {
                let tokens = pair.components(separatedBy: "=")
                if tokens.count >= 2, tokens[0].trimmingCharacters(in: .whitespaces) == name {
                    return tokens.dropFirst().joined(separator: "=")
                }
            }
            return ""
        }
        cookie.setObject(getKey, forKeyedSubscript: "getKey" as NSString)

        let setCookie: @convention(block) (String, String) -> Void = { [weak self] urlString, value in
            guard let self, let url = URL(string: urlString) else { return }
            CookieJar.shared.setCookie(value, for: self.host.sourceKey, url: url)
        }
        cookie.setObject(setCookie, forKeyedSubscript: "setCookie" as NSString)

        let replaceCookie: @convention(block) (String, String) -> Void = { [weak self] urlString, value in
            guard let self, let url = URL(string: urlString) else { return }
            CookieJar.shared.clear(sourceKey: self.host.sourceKey)
            CookieJar.shared.setCookie(value, for: self.host.sourceKey, url: url)
        }
        cookie.setObject(replaceCookie, forKeyedSubscript: "replaceCookie" as NSString)

        let removeCookie: @convention(block) (String) -> Void = { [weak self] _ in
            guard let self else { return }
            CookieJar.shared.clear(sourceKey: self.host.sourceKey)
        }
        cookie.setObject(removeCookie, forKeyedSubscript: "removeCookie" as NSString)

        context.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
    }

    private func setupCache(_ context: JSContext) {
        let cacheObject = JSEngine.newObject(in: context)

        let get: @convention(block) (String) -> String? = { [weak self] name in self?.cache[name] }
        cacheObject.setObject(get, forKeyedSubscript: "get" as NSString)

        let put: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] name, value, _ in
            self?.cache[name] = JSEngine.stringFrom(value)
        }
        cacheObject.setObject(put, forKeyedSubscript: "put" as NSString)

        let delete: @convention(block) (String) -> Void = { [weak self] name in
            self?.cache.removeValue(forKey: name)
        }
        cacheObject.setObject(delete, forKeyedSubscript: "delete" as NSString)

        let getFile: @convention(block) (String) -> String? = { [weak self] name in self?.cache[name] }
        cacheObject.setObject(getFile, forKeyedSubscript: "getFile" as NSString)

        let putFile: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] name, value, _ in
            self?.cache[name] = JSEngine.stringFrom(value)
        }
        cacheObject.setObject(putFile, forKeyedSubscript: "putFile" as NSString)

        let putMemory: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.cache[name] = JSEngine.stringFrom(value)
        }
        cacheObject.setObject(putMemory, forKeyedSubscript: "putMemory" as NSString)

        let getFromMemory: @convention(block) (String) -> String? = { [weak self] name in self?.cache[name] }
        cacheObject.setObject(getFromMemory, forKeyedSubscript: "getFromMemory" as NSString)

        let deleteMemory: @convention(block) (String) -> Void = { [weak self] name in
            self?.cache.removeValue(forKey: name)
        }
        cacheObject.setObject(deleteMemory, forKeyedSubscript: "deleteMemory" as NSString)

        context.setObject(cacheObject, forKeyedSubscript: "cache" as NSString)
    }

    // MARK: 网络响应

    private func connect(url urlString: String, header: JSValue?, method: String?, body: String?) -> JSValue {
        guard let context else { return JSEngine.undefinedValue }
        guard !urlString.isEmpty else { return JSEngine.undefinedValue }

        var options = HTTPRequestOptions()
        if let method { options.method = method }
        options.body = body

        var headers = host.headers
        if let header, !header.isUndefined, !header.isNull {
            if let dictionary = JSEngine.dictionaryFrom(header) {
                for (key, value) in dictionary { headers[key] = RuleUtil.asString(value) ?? "" }
            } else {
                let text = JSEngine.stringFrom(header)
                if let dictionary = text.jsonObject as? [String: Any] {
                    for (key, value) in dictionary { headers[key] = RuleUtil.asString(value) ?? "" }
                }
            }
        }

        let (finalURL, parsedOptions) = HTTPClient.parseURLRule(urlString)
        if parsedOptions.body != nil || parsedOptions.method != "GET" {
            options.method = parsedOptions.method
            options.body = parsedOptions.body
        }
        for (key, value) in parsedOptions.headers { headers[key] = value }
        let resolvedURL = RuleUtil.absoluteURL(finalURL, base: host.baseUrl)
        do {
            let response = try HTTPClient.shared.requestSync(
                urlString: resolvedURL,
                options: options,
                sourceKey: host.sourceKey,
                defaultHeaders: headers
            )
            return makeResponseObject(response, context: context)
        } catch {
            Log.debugLog("JS", "请求失败: " + error.localizedDescription + " url=" + resolvedURL)
            let object = JSEngine.newObject(in: context)
            object.setObject("", forKeyedSubscript: "body" as NSString)
            object.setObject("", forKeyedSubscript: "__text" as NSString)
            object.setObject(0, forKeyedSubscript: "code" as NSString)
            return object
        }
    }

    private func makeResponseObject(_ response: HTTPResponse, context: JSContext) -> JSValue {
        let object = JSEngine.newObject(in: context)
        let text = response.text
        let headerMap = response.headers
        let statusCode = response.statusCode
        let finalURL = response.finalURL?.absoluteString ?? ""

        let body: @convention(block) () -> String = { text }
        object.setObject(body, forKeyedSubscript: "body" as NSString)
        object.setObject(text, forKeyedSubscript: "__text" as NSString)
        object.setObject(text, forKeyedSubscript: "text" as NSString)

        let string: @convention(block) () -> String = { text }
        object.setObject(string, forKeyedSubscript: "string" as NSString)

        let header: @convention(block) (String) -> String = { name in
            let lowered = name.lowercased()
            for (key, value) in headerMap where key.lowercased() == lowered { return value }
            return ""
        }
        object.setObject(header, forKeyedSubscript: "header" as NSString)

        let code: @convention(block) () -> Int = { statusCode }
        object.setObject(code, forKeyedSubscript: "code" as NSString)
        object.setObject(statusCode, forKeyedSubscript: "statusCode" as NSString)

        let allHeaders: @convention(block) () -> [String: String] = { headerMap }
        object.setObject(allHeaders, forKeyedSubscript: "headers" as NSString)

        let raw: @convention(block) () -> JSValue = { [weak context] in
            guard let context else { return JSEngine.undefinedValue }
            let rawObject = JSEngine.newObject(in: context)
            let request: @convention(block) () -> JSValue = { [weak context] in
                guard let context else { return JSEngine.undefinedValue }
                let requestObject = JSEngine.newObject(in: context)
                let urlFunction: @convention(block) () -> String = { finalURL }
                requestObject.setObject(urlFunction, forKeyedSubscript: "url" as NSString)
                let headerFunction: @convention(block) (String) -> String = { name in
                    let lowered = name.lowercased()
                    for (key, value) in headerMap where key.lowercased() == lowered { return value }
                    return ""
                }
                requestObject.setObject(headerFunction, forKeyedSubscript: "header" as NSString)
                return requestObject
            }
            rawObject.setObject(request, forKeyedSubscript: "request" as NSString)
            return rawObject
        }
        object.setObject(raw, forKeyedSubscript: "raw" as NSString)

        return object
    }

    // MARK: 元素包装

    private func wrapElement(_ node: HTMLNode) -> JSValue {
        guard let context else { return JSEngine.undefinedValue }
        let object = JSEngine.newObject(in: context)

        let text: @convention(block) () -> String = { node.normalizedText }
        object.setObject(text, forKeyedSubscript: "text" as NSString)

        let ownText: @convention(block) () -> String = { node.ownText }
        object.setObject(ownText, forKeyedSubscript: "ownText" as NSString)

        let html: @convention(block) () -> String = { node.innerHTML }
        object.setObject(html, forKeyedSubscript: "html" as NSString)

        let outerHtml: @convention(block) () -> String = { node.outerHTML }
        object.setObject(outerHtml, forKeyedSubscript: "outerHtml" as NSString)

        let attr: @convention(block) (String) -> String = { name in node.attribute(name) ?? "" }
        object.setObject(attr, forKeyedSubscript: "attr" as NSString)

        let hasClass: @convention(block) (String) -> Bool = { node.hasClass($0) }
        object.setObject(hasClass, forKeyedSubscript: "hasClass" as NSString)

        let tagName: @convention(block) () -> String = { node.name }
        object.setObject(tagName, forKeyedSubscript: "tagName" as NSString)

        let select: @convention(block) (String) -> [JSValue] = { [weak self] rule in
            guard let self else { return [] }
            return CSSSelector.select(rule, in: node).map { self.wrapElement($0) }
        }
        object.setObject(select, forKeyedSubscript: "select" as NSString)

        let selectFirst: @convention(block) (String) -> JSValue = { [weak self, weak context] rule in
            guard let self, let first = CSSSelector.select(rule, in: node).first else {
                return JSValue(undefinedIn: context)
            }
            return self.wrapElement(first)
        }
        object.setObject(selectFirst, forKeyedSubscript: "selectFirst" as NSString)

        return object
    }

    /// 统一的选择入口：XPath / 传统选择器 / CSS。
    ///
    /// 书源脚本里 java.getElements('class.comic-contain@amp-img') 这类写法很常见，
    /// 传统选择器必须与规则引擎走同一套求值。
    private func selectNodes(_ rule: String, in document: HTMLNode) -> [HTMLNode] {
        let (kind, body) = RuleSyntax.detectKind(rule)
        if kind == .xpath { return XPathEngine.nodes(body, document: document) }
        if LegacySelector.isLegacy(body) { return LegacySelector.select(body, in: document) }
        return CSSSelector.select(body, in: document)
    }

    private func currentDocument() -> HTMLNode? {
        if let document = host.document { return document }
        if !src.isEmpty { return HTMLParser.parse(src) }
        return nil
    }

    // MARK: 值转换

    /// 新建一个空 JS 对象。
    ///
    /// 不要用 `JSValue(newObjectIn:) ?? ...`：该初始化器返回的是可选值，
    /// 一旦用 `??` 兜底，整个表达式的类型就退化成 `JSValue?`，
    /// 后续所有 `setObject(_:forKeyedSubscript:)` 都会编译失败
    /// （CI 上一次 86 个 error 全部出自这里）。
    /// 统一收口成一个返回非可选值的方法，既修类型又保留兜底。
    static func newObject(in context: JSContext) -> JSValue {
        if let object = JSValue(newObjectIn: context) { return object }
        return JSValue(undefinedIn: context)
    }

    /// 上下文已不可用（引擎已释放）时的占位值。
    static var undefinedValue: JSValue {
        JSValue(undefinedIn: nil)
    }



    static func stringFrom(_ value: JSValue?) -> String {
        guard let value, !value.isUndefined, !value.isNull else { return "" }
        if value.isString { return value.toString() ?? "" }
        if value.isBoolean { return value.toBool() ? "true" : "false" }
        if value.isNumber {
            let double = value.toDouble()
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return String(double)
        }
        if value.isArray || value.isObject {
            if let context = value.context,
               let stringify = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("stringify"),
               let json = stringify.call(withArguments: [value])?.toString() {
                return json
            }
        }
        return value.toString() ?? ""
    }

    static func dictionaryFrom(_ value: JSValue) -> [String: Any]? {
        if let object = value.toObject(), JSONSerialization.isValidJSONObject(object) { return object as? [String: Any] }
        let text = stringFrom(value)
        return text.jsonObject as? [String: Any]
    }

    /// 单个数组桥接的元素上限。
    ///
    /// 这条路径是「JS 返回值 → Swift 值」的唯一出口。书源里的递归通配规则
    /// 作用在 MB 级 JSON 上时，JS 侧会给出十万级元素的数组；
    /// 逐元素桥接会一次性申请巨量内存（每个元素都要建 JSValue 再转 Swift），
    /// 内存不够时进程被系统清掉。真实规则只需要前若干条，这里截断即可。
    private static let maxBridgeCount = 5_000

    /// 桥接深度上限：自引用对象（JS 里很常见）会让递归无上限展开直到栈溢出。
    private static let maxBridgeDepth = 32

    static func swiftValue(_ value: JSValue?) -> Any? {
        swiftValue(value, depth: 0)
    }

    private static func swiftValue(_ value: JSValue?, depth: Int) -> Any? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        // 自引用结构：到深度上限直接放弃展开，返回字符串表示，避免无限递归。
        guard depth < maxBridgeDepth else { return stringFrom(value) }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber {
            let double = value.toDouble()
            if double == double.rounded(), abs(double) < 1e15 { return Int64(double) }
            return double
        }
        if value.isArray {
            let array = value.toArray() ?? []
            let limited = array.count > maxBridgeCount ? Array(array.prefix(maxBridgeCount)) : array
            // value.context 可能为 nil（对象已随引擎释放）。
            // 原写法把 nil 直接传给 JSValue(object:in:)，属于未定义行为；
            // 这里没有上下文时退回字符串化，绝不构造非法 JSValue。
            guard let context = value.context else {
                // 没有上下文就无法构造 JSValue，退回原值的字符串表示，
                // 既保住了内容，也不会触发未定义行为。
                return limited.map { String(describing: $0) }
            }
            return limited.map { element -> Any? in
                // 只桥接真正的 Objective-C 对象：toArray() 正常都给 NSObject，
                // 但一旦混进纯 Swift 值，JSValue(object:) 会走未定义行为。
                guard let object = element as? NSObject else {
                    return RuleUtil.asString(element) ?? ""
                }
                return swiftValue(JSValue(object: object, in: context), depth: depth + 1)
            }
        }
        if value.isObject {
            if let object = value.toObject(), JSONSerialization.isValidJSONObject(object) { return object }
            let text = stringFrom(value)
            return text.jsonObject ?? text
        }
        return value.toString()
    }

    // MARK: - 注入前净化

    /// 把一个 Swift 值净化为「JavaScriptCore 一定认识」的形态。
    ///
    /// `JSContext.setObject(_:forKeyedSubscript:)` 只接受 Objective-C 可桥接的值
    /// （NSString / NSNumber / NSArray / NSDictionary / NSNull / block / JSValue）。
    /// 一旦传进去一个纯 Swift 类型（本项目的 `HTMLNode` 就是 pure Swift `final class`，
    /// 不继承 NSObject、没有 ObjC 元数据），JavaScriptCore 的桥接层会去反射它的
    /// 内存布局：先退化成 CoreFoundation 的对象描述，再在 Swift 运行时里读
    /// `UnsafeBufferPointer.baseAddress` —— 这一步直接触发 Swift 运行时陷阱
    /// （SIGABRT），崩在 JavaScriptCore 自己的线程里，现场只剩
    /// `JavaScriptCore → CoreFoundation → libswiftCore → abort` 一串看不懂的帧。
    ///
    /// 这不是理论问题：书源规则链里 `<js>…</js>` 的前一步结果经常就是 HTMLNode。
    /// 搜索时 `listItems` 把列表条目（HTMLNode）作为上下文交给规则，
    /// 于是任何 `@js:` 或 `{{插值}}` 都会把 HTMLNode 写进 `js.result`，
    /// 再由这里注入 JS 全局 —— 多源搜索会成百上千次走到这条路径，
    /// 这正是「搜到某个数量就闪退」而崩溃栈全是 JavaScriptCore 帧的根因。
    ///
    /// 这里在最外层出口统一净化一次：认识的类型原样保留，
    /// 不认识的降级成字符串（复用 RuleUtil 已有的文本化逻辑），
    /// 并且递归清洗容器，保证没有任何非桥接值漏进 JavaScriptCore。
    static func jsSafeValue(_ value: Any?) -> Any {
        jsSafeValue(value, depth: 0)
    }

    private static func jsSafeValue(_ value: Any?, depth: Int) -> Any {
        guard let value else { return NSNull() }
        // 深度上限：HTMLNode 互相引用，容器也可能自引用，无上限展开会栈溢出。
        if depth >= maxBridgeDepth { return RuleUtil.asString(value) ?? "" }

        if let text = value as? String { return text }
        // 纯 Swift 类型在这里被拦下，绝不进入 JavaScriptCore 的桥接层。
        if let node = value as? HTMLNode { return XPathEngine.stringValue(of: node) }
        // 数字要区分「布尔」与「数值」：Swift 里 NSNumber(1) as? Bool 也会成功，
        // 直接用 `as? Bool` 会把 JSON 里的数字 1 变成 true，脚本语义就错了。
        // 只有 CFBoolean 类型的 NSNumber 才是真正的布尔。
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number
        }
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return number }
        if let number = value as? Double { return number }
        if let number = value as? Float { return number }

        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, item) in dictionary {
                if output.count >= maxBridgeCount { break }
                output[key] = jsSafeValue(item, depth: depth + 1)
            }
            return output
        }
        if let array = value as? [Any] {
            let limited = array.count > maxBridgeCount ? Array(array.prefix(maxBridgeCount)) : array
            return limited.map { jsSafeValue($0, depth: depth + 1) }
        }

        // 兜底：文本化。宁可让脚本少看到一个字段，也不能让进程崩在桥接层。
        return RuleUtil.asString(value) ?? ""
    }
}

// MARK: - 摘要 / HMAC

enum Crypto {
    static func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func digestHex(_ text: String, algorithm: String) -> String {
        let data = Data(text.utf8)
        let bytes: [UInt8]
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5": bytes = Array(Insecure.MD5.hash(data: data))
        case "SHA1": bytes = Array(Insecure.SHA1.hash(data: data))
        case "SHA256": bytes = Array(SHA256.hash(data: data))
        case "SHA384": bytes = Array(SHA384.hash(data: data))
        case "SHA512": bytes = Array(SHA512.hash(data: data))
        default: bytes = Array(SHA256.hash(data: data))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacHex(_ text: String, algorithm: String, key: String) -> String {
        let keyData = SymmetricKey(data: Data(key.utf8))
        let data = Data(text.utf8)
        let code: [UInt8]
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5": code = Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: keyData))
        case "SHA1": code = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: keyData))
        case "SHA256": code = Array(HMAC<SHA256>.authenticationCode(for: data, using: keyData))
        case "SHA384": code = Array(HMAC<SHA384>.authenticationCode(for: data, using: keyData))
        case "SHA512": code = Array(HMAC<SHA512>.authenticationCode(for: data, using: keyData))
        default: code = Array(HMAC<SHA256>.authenticationCode(for: data, using: keyData))
        }
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
