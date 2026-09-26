import Foundation
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

    init(host: Host = Host()) {
        self.host = host
        context = JSContext(virtualMachine: JSVirtualMachine())
        setup()
    }

    // MARK: 求值

    /// 求值脚本。返回 String / Int64 / Double / Bool / JSON 对象。
    func evaluate(_ script: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return nil }

        context.setObject(key, forKeyedSubscript: "key" as NSString)
        context.setObject(page, forKeyedSubscript: "page" as NSString)
        context.setObject(host.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(src, forKeyedSubscript: "src" as NSString)
        context.setObject(host.title, forKeyedSubscript: "title" as NSString)
        if let result {
            context.setObject(result, forKeyedSubscript: "result" as NSString)
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
        let java = JSValue(newObjectIn: context)!

        let connect: @convention(block) (JSValue) -> JSValue = { [weak self] urlValue in
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

        let get: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] urlValue, headerValue in
            guard let self else { return JSValue(undefinedIn: context) }
            return self.connect(url: JSEngine.stringFrom(urlValue), header: headerValue, method: "GET", body: nil)
        }
        java.setObject(get, forKeyedSubscript: "get" as NSString)

        let post: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self] urlValue, bodyValue, headerValue in
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

        let getElement: @convention(block) (String) -> JSValue = { [weak self] rule in
            guard let self, let document = self.currentDocument() else { return JSValue(undefinedIn: context) }
            let (kind, body) = RuleSyntax.detectKind(rule)
            let nodes: [HTMLNode] = kind == .xpath
                ? XPathEngine.nodes(body, document: document)
                : CSSSelector.select(body, in: document)
            guard let first = nodes.first else { return JSValue(undefinedIn: context) }
            return self.wrapElement(first)
        }
        java.setObject(getElement, forKeyedSubscript: "getElement" as NSString)

        let getElements: @convention(block) (String) -> [JSValue] = { [weak self] rule in
            guard let self, let document = self.currentDocument() else { return [] }
            let (kind, body) = RuleSyntax.detectKind(rule)
            let nodes: [HTMLNode] = kind == .xpath
                ? XPathEngine.nodes(body, document: document)
                : CSSSelector.select(body, in: document)
            return nodes.map { self.wrapElement($0) }
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

        let queryTTF: @convention(block) (JSValue) -> JSValue = { _ in
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
        let source = JSValue(newObjectIn: context)!

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
        let book = JSValue(newObjectIn: context)!
        for key in ["name", "author", "bookUrl", "tocUrl", "origin", "originName", "coverUrl", "intro", "kind"] {
            book.setObject(host.bookInfo[key] ?? "", forKeyedSubscript: key as NSString)
        }
        for (key, value) in host.bookInfo {
            book.setObject(value, forKeyedSubscript: key as NSString)
        }
        context.setObject(book, forKeyedSubscript: "book" as NSString)

        let chapter = JSValue(newObjectIn: context)!
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
        let cookie = JSValue(newObjectIn: context)!

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
        let cacheObject = JSValue(newObjectIn: context)!

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
        guard let context else { return JSValue(undefinedIn: nil) }
        guard !urlString.isEmpty else { return JSValue(undefinedIn: nil) }

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
            let object = JSValue(newObjectIn: context)!
            object.setObject("", forKeyedSubscript: "body" as NSString)
            object.setObject("", forKeyedSubscript: "__text" as NSString)
            object.setObject(0, forKeyedSubscript: "code" as NSString)
            return object
        }
    }

    private func makeResponseObject(_ response: HTTPResponse, context: JSContext) -> JSValue {
        let object = JSValue(newObjectIn: context)!
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

        let raw: @convention(block) () -> JSValue = {
            let rawObject = JSValue(newObjectIn: context)!
            let request: @convention(block) () -> JSValue = {
                let requestObject = JSValue(newObjectIn: context)!
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
        guard let context else { return JSValue(undefinedIn: nil) }
        let object = JSValue(newObjectIn: context)!

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

        let selectFirst: @convention(block) (String) -> JSValue = { [weak self] rule in
            guard let self, let first = CSSSelector.select(rule, in: node).first else {
                return JSValue(undefinedIn: context)
            }
            return self.wrapElement(first)
        }
        object.setObject(selectFirst, forKeyedSubscript: "selectFirst" as NSString)

        return object
    }

    private func currentDocument() -> HTMLNode? {
        if let document = host.document { return document }
        if !src.isEmpty { return HTMLParser.parse(src) }
        return nil
    }

    // MARK: 值转换

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

    static func swiftValue(_ value: JSValue?) -> Any? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber {
            let double = value.toDouble()
            if double == double.rounded(), abs(double) < 1e15 { return Int64(double) }
            return double
        }
        if value.isArray {
            let array = value.toArray() ?? []
            return array.map { swiftValue(JSValue(object: $0, in: value.context)) }
        }
        if value.isObject {
            if let object = value.toObject(), JSONSerialization.isValidJSONObject(object) { return object }
            let text = stringFrom(value)
            return text.jsonObject ?? text
        }
        return value.toString()
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
