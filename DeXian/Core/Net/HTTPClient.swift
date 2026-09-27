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
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
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
        let request = try Self.buildRequest(
            urlString: urlString,
            options: options,
            sourceKey: sourceKey,
            defaultHeaders: defaultHeaders,
            base: base
        )
        let (data, response) = try await session.data(for: request)
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
        let resolved = RuleUtil.absoluteURL(urlString, base: base)
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
    func data(
        urlString: String,
        headers: [String: String] = [:],
        sourceKey: String? = nil,
        base: String? = nil
    ) async throws -> Data {
        let resolved = RuleUtil.absoluteURL(urlString, base: base)
        guard let url = URL(string: resolved) else {
            throw NetworkError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sourceKey, let cookie = CookieJar.shared.cookieHeader(for: sourceKey, url: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await session.data(for: request)
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

    /// 解析 url,{"method":"POST","body":...} 形式的规则。
    static func parseURLRule(_ rule: String) -> (url: String, options: HTTPRequestOptions) {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = HTTPRequestOptions()
        guard !text.isEmpty else { return (text, options) }

        if let range = text.range(of: ",{") {
            let urlPart = String(text[..<range.lowerBound])
            let optionPart = String(text[range.lowerBound...].dropFirst())
            if let dictionary = optionPart.jsonObject as? [String: Any] {
                options = parseOptions(dictionary)
                text = urlPart
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), options)
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
        return options
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

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "链接无效：" + value
        case .invalidResponse: return "服务器响应异常"
        case .emptyContent: return "内容为空"
        case .httpStatus(let code): return "请求失败（HTTP " + String(code) + "）"
        case .timeout: return "请求超时"
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
