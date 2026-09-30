import Foundation

/// 单次请求结果
struct HTTPResponse {
    var data: Data
    var text: String
    var headers: [String: String]
    var statusCode: Int
    var finalURL: URL?
    var raw: HTTPURLResponse?

    func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        for (key, value) in headers where key.lowercased() == lowered { return value }
        return nil
    }
}

/// 请求参数（对应 Legado 的 url,{...} 语法）
struct HTTPRequestOptions {
    var method: String = "GET"
    var body: String?
    var headers: [String: String] = [:]
    var charset: String?
    var proxy: String?
    var webView = false
    var retry: Int = 0
    var timeout: TimeInterval = 30
    /// Legado 的 `{"type":...}`：响应体按**十六进制**文本给出。
    ///
    /// 见 `dataURIResponse`。只有 `data:` 地址上的 type 才有意义。
    var type: String?
}

/// HTTP 客户端：处理 GBK 解码、Cookie 按书源隔离、自定义请求头。
final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 搜索要并发几百个源：单个请求最长 15s，避免一个慢源把整轮搜索拖到几分钟。
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        // 断网 / 连不上时立刻失败。置 true 会一直等网络恢复，
        // 表现就是搜索长时间卡住不动（书源站点常常已经挂了）。
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        ]
        let delegate = HTTPClientDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// 发起异步请求
    ///
    /// - Parameter base: 相对地址的解析基准。书源里大量使用
    ///   "/search.php?searchkey={{key}}" 这类相对写法，缺少基准时
    ///   URL(string:) 会抛 NSURLErrorUnsupportedURL(-1002)。
    func request(
        urlString: String,
        options: HTTPRequestOptions = HTTPRequestOptions(),
        sourceKey: String? = nil,
        defaultHeaders: [String: String] = [:],
        base: String? = nil
    ) async throws -> HTTPResponse {
        // data: URI 不发请求，直接解码（Legado getByteArrayIfDataUri 的等价物）
        if let response = Self.dataURIResponse(urlString: urlString, options: options) {
            return response
        }
        let request = try Self.buildRequest(
            urlString: urlString,
            options: options,
            sourceKey: sourceKey,
            defaultHeaders: defaultHeaders,
            base: base
        )
        let (data, response) = try await session.data(for: request)
        try Self.checkDeclaredSize(response)
        guard data.count <= Self.maxResponseBytes else {
            throw NetworkError.responseTooLarge(data.count)
        }
        return try Self.decode(data: data, response: response, options: options, sourceKey: sourceKey)
    }

    /// 组装 URLRequest（异步 / 同步共用，保证两条路径行为一致）
    private static func buildRequest(
        urlString: String,
        options: HTTPRequestOptions,
        sourceKey: String?,
        defaultHeaders: [String: String],
        base: String?
    ) throws -> URLRequest {
        let resolved = RuleUtil.sanitizeURL(RuleUtil.absoluteURL(urlString, base: base))
        guard let url = URL(string: resolved) else {
            throw NetworkError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = options.method.uppercased()
        request.timeoutInterval = options.timeout

        var headers = defaultHeaders
        for (key, value) in options.headers { headers[key] = value }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(BrowserUserAgent.mobile, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }

        if let sourceKey, let cookie = CookieJar.shared.cookieHeader(for: sourceKey, url: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        if let body = options.body {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    /// 单个响应体的硬上限。
    ///
    /// 正常书源页面在几百 KB 量级，64MB 已经远超任何真实网页。
    /// 设这道闸门是为了挡住「服务端声明了一个超大 Content-Length」的情况：
    /// 那种响应一旦真的收下来，内存会被瞬间吃掉，进程直接被系统杀掉 ——
    /// 表现就是「点开某本书就闪退」，而且完全没有崩溃报告可查。
    static let maxResponseBytes = 64 * 1024 * 1024

    /// 声明体积就超限的响应：直接放弃，不必先把数据收进内存。
    static func checkDeclaredSize(_ response: URLResponse) throws {
        let declared = response.expectedContentLength
        guard declared > Int64(maxResponseBytes) else { return }
        throw NetworkError.responseTooLarge(Int(declared))
    }

    /// 把 URLSession 的响应整理成 HTTPResponse（异步 / 同步共用）
    private static func decode(
        data: Data,
        response: URLResponse,
        options: HTTPRequestOptions,
        sourceKey: String?
    ) throws -> HTTPResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        if let sourceKey {
            CookieJar.shared.store(response: httpResponse, sourceKey: sourceKey)
        }

        var headerMap: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyString = key as? String {
                headerMap[keyString] = RuleUtil.asString(value) ?? ""
            }
        }

        let preferredEncoding = options.charset.flatMap { Charset.encoding(named: $0) }
            ?? Charset.fromContentType(headerMap["Content-Type"] ?? headerMap["content-type"])
        let text = Charset.decode(data, preferred: preferredEncoding)

        return HTTPResponse(
            data: data,
            text: text,
            headers: headerMap,
            statusCode: httpResponse.statusCode,
            finalURL: httpResponse.url,
            raw: httpResponse
        )
    }

    /// 下载二进制（图片 / 音频）
    /// 请求资源类型：图片要走更宽松的解码与更严格的响应校验。
    enum ResourceKind {
        case text
        case image
    }

    /// 下载二进制数据（图片、字体等）。
    ///
    /// 这里必须复用 buildRequest：图片请求同样需要 UA / Accept / Cookie，
    /// 否则图床会把请求当成脚本，返回 403 或者返回一张提示图，
    /// 表现就是「所有漫画图都加载失败」。
    func data(
        urlString: String,
        headers: [String: String] = [:],
        sourceKey: String? = nil,
        base: String? = nil,
        kind: ResourceKind = .image
    ) async throws -> Data {
        var options = HTTPRequestOptions()
        options.headers = headers
        if kind == .image {
            options.headers["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        }
        let request = try Self.buildRequest(
            urlString: urlString,
            options: options,
            sourceKey: sourceKey,
            defaultHeaders: [:],
            base: base
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        // 图片同样要有上限：漫画图床偶尔返回一整张超大原图，
        // 收进内存后还没等到解码就已经被系统回收了。
        try Self.checkDeclaredSize(httpResponse)
        if let sourceKey {
            CookieJar.shared.store(response: httpResponse, sourceKey: sourceKey)
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw NetworkError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else { throw NetworkError.emptyContent }
        // 防盗链站点常用「返回一张 HTML 错误页」代替 403，
        // 这里直接拦掉，免得把网页正文当图片去解码。
        if let mime = httpResponse.mimeType?.lowercased(),
           mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") {
            throw NetworkError.invalidResponse
        }
        return data
    }


    /// 同步请求：供 JS 引擎的 java.ajax / java.connect / java.get / java.post 使用。
    ///
    /// 这里刻意不用 Task / async-await：JS 求值本身跑在 Swift 并发的协作线程池上，
    /// 同步等待会占住池里的线程，池子被占满后回调再也拿不到线程，直接死锁。
    /// 改用 URLSession 的 completionHandler（回调在自己的 delegate 队列上执行，
    /// 与协作线程池无关）+ 信号量等待，等待上限取请求超时的兜底值。
    func requestSync(
        urlString: String,
        options: HTTPRequestOptions = HTTPRequestOptions(),
        sourceKey: String? = nil,
        defaultHeaders: [String: String] = [:],
        base: String? = nil
    ) throws -> HTTPResponse {
        if let response = Self.dataURIResponse(urlString: urlString, options: options) {
            return response
        }
        let request = try Self.buildRequest(
            urlString: urlString,
            options: options,
            sourceKey: sourceKey,
            defaultHeaders: defaultHeaders,
            base: base
        )

        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.set(.failure(error))
                return
            }
            guard let data, let response else {
                box.set(.failure(NetworkError.invalidResponse))
                return
            }
            do {
                box.set(.success(try Self.decode(data: data, response: response,
                                               options: options, sourceKey: sourceKey)))
            } catch {
                box.set(.failure(error))
            }
        }
        task.resume()

        // 请求本身已有 30s 级超时；这里再兜一层，保证任何情况下都不会永久卡住。
        let limit = min(max(options.timeout, 30), 90)
        guard semaphore.wait(timeout: .now() + limit + 5) == .success else {
            task.cancel()
            throw NetworkError.timeout
        }
        switch box.result {
        case .success(let response): return response
        case .failure(let error): throw error
        case .none: throw NetworkError.invalidResponse
        }
    }

    /// 解析 `url,{"method":"POST","body":...}` 形式的规则。
    ///
    /// 实测书源里的尾随选项**不是严格 JSON**，而是 JS 对象字面量：
    /// 键名不加引号（`{webView:true}`）、字符串用单引号
    /// （`{credentials:'omit'}`）、引号是全角（`{webView:“true”}`）、
    /// 甚至塞变量（`{bookId:BID}`）。宽容解析见 `optionObject(from:)`。
    static func parseURLRule(_ rule: String) -> (url: String, options: HTTPRequestOptions) {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = HTTPRequestOptions()
        guard !text.isEmpty else { return (text, options) }

        if let split = splitTrailingOptions(text) {
            if let dictionary = optionObject(from: split.options) {
                options = parseOptions(dictionary)
            }
            // 选项即使解析不出来，地址也必须是干净的：残留 “,{...}”
            // 会让请求 100% 失败（旧实现就是这么丢掉整条目录规则的，
            // 界面表现就是「目录获取失败」）。
            text = split.url
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), options)
    }

    /// 从规则里切出「地址 + 尾随选项」。
    ///
    /// 只有**括号配平**的那一段 `,{...}` 才算选项：正文规则里出现 `,{`
    /// 是内容而不是选项，按首个 `,{` 无脑切会把地址切坏。
    static func splitTrailingOptions(_ text: String) -> (url: String, options: String)? {
        var searchEnd = text.endIndex
        while let range = text.range(of: ",{", options: .backwards, range: text.startIndex..<searchEnd) {
            let urlPart = String(text[..<range.lowerBound])
            let optionText = String(text[range.lowerBound...].dropFirst())
            if !urlPart.isEmpty && balancedBraces(optionText) {
                return (urlPart, optionText)
            }
            searchEnd = range.lowerBound
        }
        return nil
    }

    /// `{...}` 是否括号配平，且外层恰好一对。
    private static func balancedBraces(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 2, characters[0] == "{", characters[characters.count - 1] == "}" else {
            return false
        }
        var depth = 0
        var quote: Character?
        var escaped = false
        for (index, character) in characters.enumerated() {
            if let closing = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == closing {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "“" {
                quote = "”"
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 { return false }
                if depth == 0 && index != characters.count - 1 { return false }
            }
        }
        return depth == 0 && quote == nil
    }

    /// 按 JS 对象字面量的语义解析尾随选项。
    ///
    /// 顺序：严格 JSON → 改写宽松写法（键名补引号、单引号转双引号）
    /// → 仍失败就当作「没有选项」。
    static func optionObject(from text: String) -> [String: Any]? {
        let normalized = normalizeFullWidthJSON(text)
        if let dictionary = normalized.jsonObject as? [String: Any] {
            return dictionary
        }
        return jsonObjectText(normalized).jsonObject as? [String: Any]
    }

    /// 把 JS 对象字面量改写成合法 JSON。
    ///
    /// 处理：键名不加引号（`{webView:true}` → `{"webView":true}`）、
    /// 单引号字符串（`{credentials:'omit'}` → `{"credentials":"omit"}`）。
    /// 值里若是变量（`{bookId:BID}`）无法求值，改写后依旧非法，
    /// `JSONSerialization` 会拒绝，调用方按「没有选项」处理。
    static func jsonObjectText(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        var quote: Character?

        while index < characters.count {
            let character = characters[index]

            if let closing = quote {
                if character == "\\" && closing == "\"" {
                    output.append(character)
                    if index + 1 < characters.count {
                        output.append(characters[index + 1])
                        index += 2
                        continue
                    }
                } else if character == closing {
                    output.append("\"")
                    quote = nil
                    index += 1
                    continue
                } else if character == "\"" {
                    output.append("\\")
                }
                output.append(character)
                index += 1
                continue
            }

            if character == "\"" || character == "'" {
                output.append("\"")
                quote = character
                index += 1
                continue
            }

            if character == "_" || character == "$" || character.isLetter {
                var end = index + 1
                while end < characters.count {
                    let next = characters[end]
                    if next == "_" || next == "$" || next.isLetter || next.isNumber {
                        end += 1
                    } else {
                        break
                    }
                }
                var probe = end
                while probe < characters.count && characters[probe].isWhitespace { probe += 1 }
                if probe < characters.count && characters[probe] == ":" {
                    output.append("\"")
                    output.append(contentsOf: characters[index..<end])
                    output.append("\"")
                } else {
                    output.append(contentsOf: characters[index..<end])
                }
                index = end
                continue
            }

            output.append(character)
            index += 1
        }
        return output
    }

    /// 把书源里误用的全角引号 / 冒号还原成 ASCII。
    ///
    /// 实测有书源写成 `href@js:result+',{webView:“true”}'` —— 引号是全角
    /// `“ ”`。这在 JSON 里是普通字符，解析必然失败，
    /// 于是整条目录规则作废，界面表现就是「目录获取失败」（天天评书、
    /// 恋听网吧等源就是这么写的）。
    ///
    /// 只替换出现在 `,{` 之后的这段选项文本：正文规则里的全角引号
    /// 是内容的一部分，全局替换会把正文改坏。
    static func normalizeFullWidthJSON(_ text: String) -> String {
        guard text.contains("“") || text.contains("”") || text.contains("：") || text.contains("，") else {
            return text
        }
        return text
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "｛", with: "{")
            .replacingOccurrences(of: "｝", with: "}")
            .replacingOccurrences(of: "［", with: "[")
            .replacingOccurrences(of: "］", with: "]")
    }

    static func parseOptions(_ dictionary: [String: Any]) -> HTTPRequestOptions {
        var options = HTTPRequestOptions()
        if let method = dictionary.str("method") { options.method = method.uppercased() }
        if let body = dictionary.firstValue(["body", "data", "postData"]) {
            if let text = body as? String {
                options.body = text
            } else if let data = try? JSONSerialization.data(withJSONObject: body),
                      let text = String(data: data, encoding: .utf8) {
                options.body = text
            }
        }
        if let headers = dictionary.dict("headers", "header") {
            for (key, value) in headers {
                options.headers[key] = RuleUtil.asString(value) ?? ""
            }
        }
        if let charset = dictionary.str("charset") { options.charset = charset }
        if let proxy = dictionary.str("proxy") { options.proxy = proxy }
        if let webView = dictionary.firstValue(["webView", "webview"]) { options.webView = RuleUtil.asBool(webView) }
        if let retry = dictionary.int("retry") { options.retry = retry }
        if let type = dictionary.str("type") { options.type = type }
        return options
    }

    /// `data:;base64,<payload>` 形式的地址：**不发网络请求**，直接解码当响应体。
    ///
    /// 对齐 Legado `AnalyzeUrl.getByteArrayIfDataUri()`：它在真正发请求之前
    /// 先匹配 dataUriRegex，命中就 `Base64.decode(payload)` 当结果返回。
    /// 携带 `{"type":...}` 选项时（`AnalyzeUrl.getStrResponseAwait`:
    /// `if (type != null) return StrResponse(url, HexUtil.encodeHexStr(bytes))`）
    /// 响应体是**十六进制文本**而不是原文 —— 书源里配套写的是
    /// `java.hexDecodeToString(src)`。
    ///
    /// 为什么必须支持：实测 826 个书源 / 21 个订阅源把分类地址写成
    /// `名称::data:;base64,MA==,{"type":0}`，payload 是**序号**（`MA==` = "0"）。
    /// 旧实现把整串当真实 URL 去请求，URLSession 直接抛 unsupportedURL，
    /// 表现是「这些源的分类一点就报错 / 列表永远空」。
    /// RSS 616「AI风月」的路线切换就是这条路。
    static func dataURIResponse(urlString: String, options: HTTPRequestOptions) -> HTTPResponse? {
        let text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = String(text[text.startIndex..<comma])
        // 只处理 base64；`data:text/plain,...` 这类本工程没有使用场景。
        guard header.lowercased().contains("base64") else { return nil }
        let payload = String(text[text.index(after: comma)...])
        let bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
        // type 存在时给十六进制文本（书源据此走 hexDecodeToString）。
        let body = options.type == nil
            ? (String(data: bytes, encoding: .utf8) ?? "")
            : bytes.map { String(format: "%02x", $0) }.joined()
        return HTTPResponse(
            data: bytes,
            text: body,
            headers: [:],
            statusCode: 200,
            finalURL: nil,
            raw: nil
        )
    }
}

/// 在线程间传递请求结果
final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<HTTPResponse, Error>?

    var result: Result<HTTPResponse, Error>? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ value: Result<HTTPResponse, Error>) {
        lock.lock(); defer { lock.unlock() }
        storage = value
    }
}

enum NetworkError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case emptyContent
    case httpStatus(Int)
    case timeout
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "链接无效：" + value
        case .invalidResponse: return "服务器响应异常"
        case .emptyContent: return "内容为空"
        case .httpStatus(let code): return "请求失败（HTTP " + String(code) + "）"
        case .timeout: return "请求超时"
        case .responseTooLarge(let bytes):
            return "内容过大（" + String(bytes / 1024 / 1024) + "MB），已中止"
        }
    }
}

enum BrowserUserAgent {
    static let mobile = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}

/// 重定向时保留关键请求头
final class HTTPClientDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var modified = request
        if modified.value(forHTTPHeaderField: "User-Agent") == nil,
           let original = task.originalRequest?.value(forHTTPHeaderField: "User-Agent") {
            modified.setValue(original, forHTTPHeaderField: "User-Agent")
        }
        if modified.value(forHTTPHeaderField: "Referer") == nil,
           let original = task.originalRequest?.value(forHTTPHeaderField: "Referer") {
            modified.setValue(original, forHTTPHeaderField: "Referer")
        }
        completionHandler(modified)
    }
}
