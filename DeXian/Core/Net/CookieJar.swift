import Foundation

/// Cookie 存储：按书源隔离（对应 Legado 的 CookieJar 开关）。
/// 只保存内存 + 简单落盘，避免引入第三方依赖。
final class CookieJar {
    static let shared = CookieJar()

    private struct Cookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
    }

    private var storage: [String: [Cookie]] = [:]
    private let lock = NSLock()

    private init() {
        load()
    }

    /// 书源 key -> cookie 字典
    func cookieHeader(for sourceKey: String, url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cookies = storage[sourceKey], !cookies.isEmpty else { return nil }
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let matched = cookies.filter { cookie in
            let domainMatches = host == cookie.domain || host.hasSuffix("." + cookie.domain)
            let pathMatches = path.hasPrefix(cookie.path)
            let notExpired = cookie.expires.map { $0 > Date() } ?? true
            return domainMatches && pathMatches && notExpired
        }
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 保存响应里的 Set-Cookie。
    func store(response: HTTPURLResponse, sourceKey: String) {
        let headerFields = response.allHeaderFields
        var setCookies: [String] = []
        for (key, value) in headerFields {
            guard let keyString = key as? String, keyString.lowercased() == "set-cookie" else { continue }
            if let list = value as? [String] {
                setCookies.append(contentsOf: list)
            } else if let single = value as? String {
                setCookies.append(single)
            }
        }
        guard !setCookies.isEmpty, let url = response.url else { return }

        lock.lock()
        defer { lock.unlock() }
        var cookies = storage[sourceKey] ?? []
        for raw in setCookies {
            guard let parsed = CookieJar.parse(raw, url: url) else { continue }
            cookies.removeAll { $0.name == parsed.name && $0.domain == parsed.domain && $0.path == parsed.path }
            cookies.append(parsed)
        }
        storage[sourceKey] = cookies
        save()
    }

    func setCookie(_ cookieString: String, for sourceKey: String, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        var cookies = storage[sourceKey] ?? []
        guard let parsed = CookieJar.parse(cookieString, url: url) else { return }
        cookies.removeAll { $0.name == parsed.name && $0.domain == parsed.domain }
        cookies.append(parsed)
        storage[sourceKey] = cookies
        save()
    }

    func clear(sourceKey: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[sourceKey] = []
        save()
    }

    /// 写入「一整串」cookie（`a=1; b=2` 或 `a=1, b=2` 形态）。
    ///
    /// `setCookie` 只认单个 `name=value; attr=…`，而
    /// `cookie.mapToCookie(response.cookies())` 这类书源给的是
    /// **多组**键值对拼起来的串。直接丢给 `setCookie` 只会存下第一组，
    /// 其余全丢 —— 表现就是「登录成功了，但只有部分接口带得上 cookie」。
    func setCookiePairs(_ header: String, for sourceKey: String, url: URL) {
        for pair in CookieJar.splitPairs(header) {
            setCookie(pair, for: sourceKey, url: url)
        }
    }

    /// 把 cookie 串切成一组组 `name=value`。
    ///
    /// 逗号分隔时要避开 `Expires=Wed, 21 Oct ...` 里的日期逗号：
    /// 只有当逗号后面跟的是 `name=` 形态时才当作分隔符。
    static func splitPairs(_ header: String) -> [String] {
        var pairs: [String] = []
        for segment in header.components(separatedBy: ";") {
            for candidate in CookieJar.splitByComma(segment) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // 属性（path / domain / expires / httponly …）没有等号或不是键值对，跳过
                let tokens = trimmed.components(separatedBy: "=")
                guard tokens.count >= 2, !tokens[0].isEmpty else { continue }
                let name = tokens[0].trimmingCharacters(in: .whitespaces)
                let lowered = name.lowercased()
                if ["path", "domain", "expires", "max-age", "samesite", "comment"].contains(lowered) { continue }
                if lowered.contains(" ") { continue }
                pairs.append(trimmed)
            }
        }
        return pairs
    }

    private static func splitByComma(_ value: String) -> [String] {
        var results: [String] = []
        var current = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "," {
                let rest = value[value.index(after: index)...]
                let head = rest.prefix { $0 == " " || $0 == "\t" }
                let after = rest.dropFirst(head.count)
                let token = after.prefix { $0 != "=" && $0 != ";" && $0 != "," }
                // 逗号后是「标识符 + =」才认定为分组分隔
                if !token.isEmpty, !token.contains(" "), token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                    results.append(current)
                    current = ""
                    index = value.index(index, offsetBy: 1)
                    continue
                }
            }
            current.append(character)
            index = value.index(after: index)
        }
        results.append(current)
        return results
    }

    private static func parse(_ raw: String, url: URL) -> Cookie? {
        let parts = raw.components(separatedBy: ";")
        guard let first = parts.first else { return nil }
        let pair = first.components(separatedBy: "=")
        guard pair.count >= 2 else { return nil }
        let name = pair[0].trimmingCharacters(in: .whitespaces)
        let value = pair.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var domain = url.host ?? ""
        var path = "/"
        var expires: Date?
        for attribute in parts.dropFirst() {
            let tokens = attribute.components(separatedBy: "=")
            let key = tokens[0].trimmingCharacters(in: .whitespaces).lowercased()
            let attributeValue = tokens.count > 1 ? tokens.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "domain": domain = attributeValue.hasPrefix(".") ? String(attributeValue.dropFirst()) : attributeValue
            case "path": path = attributeValue.isEmpty ? "/" : attributeValue
            case "max-age":
                if let seconds = TimeInterval(attributeValue) { expires = Date().addingTimeInterval(seconds) }
            case "expires":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                expires = formatter.date(from: attributeValue)
            default: break
            }
        }
        return Cookie(name: name, value: value, domain: domain, path: path, expires: expires)
    }

    private var storageURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("cookies.json")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: [Cookie]].self, from: data) else { return }
        storage = decoded
    }
}
