import Foundation
import CoreFoundation

/// 规则引擎通用工具：类型转换、正则、URL 规范化、文本处理。
enum RuleUtil {

    // MARK: 类型

    static func asString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let text = value as? String { return text }
        if let text = value as? NSString { return text as String }
        if let node = value as? HTMLNode { return XPathEngine.stringValue(of: node) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return number.stringValue
        }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? Double {
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        }
        if let number = value as? Int { return String(number) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let array = value as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return array.map { asString($0) ?? "" }.joined(separator: "\n")
        }
        return String(describing: value)
    }

    static func asDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Double(trimmed)
        }
        if let node = value as? HTMLNode {
            return Double(HTMLNode.normalizeWhitespace(XPathEngine.stringValue(of: node)))
        }
        return nil
    }

    static func isNumeric(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNumber { return true }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && Double(trimmed) != nil
        }
        if value is Double || value is Int { return true }
        return false
    }

    static func asBool(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(lowered) { return true }
            if ["false", "0", "no", ""].contains(lowered) { return false }
            return true
        }
        if let array = value as? [Any] { return !array.isEmpty }
        return true
    }

    // MARK: 正则

    static func regexMatch(_ text: String, pattern: String) -> [String] {
        guard !pattern.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        for match in regex.matches(in: text, options: [], range: range) {
            // 优先返回第一个捕获组，没有捕获组时返回整体
            if match.numberOfRanges > 1, let groupRange = Range(match.range(at: 1), in: text) {
                results.append(String(text[groupRange]))
            } else if let fullRange = Range(match.range, in: text) {
                results.append(String(text[fullRange]))
            }
        }
        return results
    }

    static func regexFirst(_ text: String, pattern: String) -> String? {
        regexMatch(text, pattern: pattern).first
    }

    static func regexReplace(_ text: String, pattern: String, replacement: String) -> String {
        guard !pattern.isEmpty else { return text }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let normalizedReplacement = normalizeReplacement(replacement)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: normalizedReplacement)
    }

    /// 把 Legado 的 "$1" / "$.1" / "\$1" 归一化为 NSRegularExpression 模板格式。
    private static func normalizeReplacement(_ replacement: String) -> String {
        var value = replacement.replacingOccurrences(of: "\\$", with: "$")
        // $.1 -> $1
        value = value.replacingOccurrences(of: "$.", with: "$")
        return value
    }

    static func isRegexPattern(_ rule: String) -> Bool {
        rule.hasPrefix(":") || rule.hasPrefix(":regex:")
    }

    // MARK: URL

    /// 相对链接转绝对链接。跳过 data:/javascript:/特殊 scheme。
    static func absoluteURL(_ url: String, base: String?) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return value }
        if value.hasPrefix("data:") || value.hasPrefix("javascript:") || value.hasPrefix("mailto:") {
            return value
        }
        if value.hasPrefix("//") {
            if let scheme = base.flatMap({ URL(string: $0)?.scheme }) {
                return scheme + ":" + value
            }
            return "https:" + value
        }
        if hasScheme(value) { return value }
        guard let base, !base.isEmpty else { return value }

        // 支持书源里的 {{page}} 之类占位符已经替换后的普通路径
        if value.hasPrefix("#") {
            return base + value
        }
        if value.hasPrefix("/") {
            if let baseURL = URL(string: base), let host = baseURL.host {
                let scheme = baseURL.scheme ?? "https"
                let port = baseURL.port.map { ":" + String($0) } ?? ""
                return scheme + "://" + host + port + value
            }
            return value
        }
        if let resolved = URL(string: value, relativeTo: URL(string: base)) {
            return resolved.absoluteString
        }
        // 退化为字符串拼接
        if let lastSlash = base.lastIndex(of: "/") {
            return String(base[..<lastSlash]) + "/" + value
        }
        return base + "/" + value
    }

    /// 求值内嵌的 JS 段，对齐 Legado 的 AnalyzeUrl.analyzeJs。
    ///
    /// 书源里会写成 `<js>if(page==1){source.setVariable('')}</js>index.php?action=search&p={{page}}`：
    /// JS 段先执行，其返回值与后面的静态片段拼接成最终地址；
    /// 片段里的 `@result` 是上一段结果的占位符。
    /// 只有 `@js:` 前缀（没有闭合标签）时，整条规则都当作脚本。
    static func resolveJSSegments(_ rule: String, evaluate: (String) -> String) -> String {
        guard rule.contains("<js>") || rule.contains("<JS>") || rule.contains("@js:") else { return rule }
        let text = rule
        // 裸 @js: 前缀：整串都是脚本
        if let range = text.range(of: "@js:", options: [.caseInsensitive]),
           text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return evaluate(String(text[range.upperBound...]))
        }

        var result = text
        var cursor = text.startIndex
        while let open = text.range(of: "<js>", options: [.caseInsensitive], range: cursor..<text.endIndex),
              let close = text.range(of: "</js>", options: [.caseInsensitive], range: open.upperBound..<text.endIndex) {
            let script = String(text[open.upperBound..<close.lowerBound])
            let prefix = String(text[cursor..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { result = prefix.replacingOccurrences(of: "@result", with: result) }
            result = evaluate(script)
            cursor = close.upperBound
        }
        let tail = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result = tail.replacingOccurrences(of: "@result", with: result) }
        return result
    }

    /// 从 JS 返回的 JSON 里抽取图片地址。
    ///
    /// 漫画源的正文规则常用 java.getElements(...) 组装出
    /// [{"link":"https://..."}] 这样的对象数组，属性名不固定。
    static func imageLinksFromJSON(_ text: String) -> [String] {
        guard let json = text.jsonObject else { return [] }
        var results: [String] = []
        let keys = ["link", "src", "url", "image", "img", "data-src", "dataSrc", "original"]

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for key in keys {
                    if let raw = dictionary[key], let url = asString(raw), !url.isEmpty {
                        results.append(url)
                        return
                    }
                }
                for (_, nested) in dictionary { visit(nested) }
                return
            }
            if let array = value as? [Any] {
                for nested in array { visit(nested) }
                return
            }
        }

        visit(json)
        return results
    }

    static func hasScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = String(value[..<colon])
        guard !scheme.isEmpty, scheme.count < 12 else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    // MARK: 文本

    /// 清理 HTML 实体与零宽字符
    static func cleanText(_ text: String) -> String {
        var value = text
        value = value.replacingOccurrences(of: "\u{200b}", with: "")
        value = value.replacingOccurrences(of: "\u{feff}", with: "")
        value = value.replacingOccurrences(of: "\u{00ad}", with: "")
        return value
    }

    static func stripHTMLTags(_ text: String) -> String {
        regexReplace(text, pattern: "<[^>]+>", replacement: "")
    }

    /// 提取字符串中的 URL（用于从 HTML 属性/JS 中抽取链接）
    static func extractURLs(_ text: String) -> [String] {
        let pattern = "(?:https?:)?//[^\\s\"'<>\\\\)]+"
        return regexMatch(text, pattern: pattern)
    }
}
