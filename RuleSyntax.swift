import Foundation

/// 规则语法解析工具：规则标志识别、规则链拆分、替换规则解析。
enum RuleSyntax {

    enum Kind {
        case css
        case xpath
        case json
        case regex
        case javascript
        case literal
    }

    /// 识别规则种类，返回 (种类, 规则主体)。
    static func detectKind(_ rule: String) -> (Kind, String) {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("@js:") || text.hasPrefix("@JS:") {
            return (.javascript, String(text.dropFirst(4)))
        }
        if text.hasPrefix("<js>") {
            return (.javascript, extractTagBody(text, tag: "js"))
        }

        let lowered = text.lowercased()
        if lowered.hasPrefix("@xpath:") { return (.xpath, String(text.dropFirst(7))) }
        if lowered.hasPrefix("@css:") { return (.css, String(text.dropFirst(5))) }
        if lowered.hasPrefix("@json:") { return (.json, String(text.dropFirst(6))) }
        if lowered.hasPrefix("@regex:") { return (.regex, String(text.dropFirst(7))) }
        if text.hasPrefix("@@") { return (.css, String(text.dropFirst(2))) }

        if text.hasPrefix("//") || text.hasPrefix("(/") || text.hasPrefix("./") {
            return (.xpath, text)
        }
        if text.hasPrefix("$") { return (.json, text) }
        if text.hasPrefix(":regex:") { return (.regex, String(text.dropFirst(7))) }
        if text.hasPrefix(":") { return (.regex, String(text.dropFirst(1))) }

        // 花括号插值 / 纯文本（如“全部”）当作字面量
        if text.contains("{{") { return (.literal, text) }
        if text.hasPrefix("{") && text.hasSuffix("}") { return (.literal, text) }

        return (.css, text)
    }

    /// 按顶层 at 符号拆分规则链。
    /// XPath 谓词里的属性符号与 JS 中的对象访问都会被正确跳过。
    static func splitChain(_ rule: String) -> [String] {
        let characters = Array(rule)
        var segments: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index += 1
                continue
            }
            if character == "[" || character == "(" || character == "{" {
                depth += 1
                current.append(character)
                index += 1
                continue
            }
            if character == "]" || character == ")" || character == "}" {
                depth -= 1
                current.append(character)
                index += 1
                continue
            }
            if depth == 0, character == "@" {
                let rest = String(characters[(index + 1)...])
                if isChainSeparator(rest) {
                    segments.append(current)
                    current = ""
                    index += 1
                    continue
                }
            }
            current.append(character)
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// 判断 at 符号后面是否是已知的链式标志（属性名 / js / json / css 等）。
    private static func isChainSeparator(_ rest: String) -> Bool {
        guard !rest.isEmpty else { return false }
        let lowered = rest.lowercased()
        let markers = ["js:", "json:", "css:", "xpath:", "regex:", "textnodes", "outerhtml",
                       "owntext", "text", "html", "attr:", "all"]

        for marker in markers where lowered.hasPrefix(marker) {
            // 带冒号的标志（js: / json: / css: / attr:）后面直接跟脚本或路径，
            // 一定是链分隔符，不能再要求后续字符不是标识符。
            if marker.hasSuffix(":") { return true }
            let remainder = lowered.dropFirst(marker.count)
            if remainder.isEmpty { return true }
            if let first = remainder.first, !isIdentifierCharacter(first) { return true }
        }

        // 属性名形式：@href / @src / @data-xxx / @id
        var name = ""
        for character in rest {
            if isIdentifierCharacter(character) { name.append(character) } else { break }
        }
        guard !name.isEmpty else { return false }
        // 属性名后必须是链结束或下一个链标志
        let remainder = rest.dropFirst(name.count)
        if remainder.isEmpty { return true }
        if remainder.hasPrefix("@") { return true }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// 拆分双井号后处理规则，返回 (核心规则, [(正则, 替换)])。
    static func splitReplaceRule(_ rule: String) -> (String, [(String, String)]) {
        guard let range = findTopLevel(rule, marker: "##") else { return (rule, []) }
        let core = String(rule[..<range.lowerBound])
        var rest = String(rule[range.upperBound...])
        var patterns: [(String, String)] = []

        while !rest.isEmpty {
            while rest.hasPrefix("#") { rest = String(rest.dropFirst()) }
            guard !rest.isEmpty else { break }

            guard let separator = findTopLevel(rest, marker: "##") else {
                let pattern = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pattern.isEmpty { patterns.append((pattern, "")) }
                break
            }
            let pattern = String(rest[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            var remainder = String(rest[separator.upperBound...])
            var replacement = ""
            if let next = findTopLevel(remainder, marker: "##") {
                replacement = String(remainder[..<next.lowerBound])
                remainder = String(remainder[next.upperBound...])
            } else if let hashIndex = remainder.firstIndex(of: "#") {
                replacement = String(remainder[..<hashIndex])
                remainder = String(remainder[hashIndex...])
            } else {
                replacement = remainder
                remainder = ""
            }
            if !pattern.isEmpty { patterns.append((pattern, replacement)) }
            rest = remainder
        }
        return (core, patterns)
    }

    private static func findTopLevel(_ text: String, marker: String) -> Range<String.Index>? {
        let characters = Array(text)
        let markerCharacters = Array(marker)
        var depth = 0
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" { quote = character; index += 1; continue }
            if character == "[" || character == "(" || character == "{" { depth += 1; index += 1; continue }
            if character == "]" || character == ")" || character == "}" { depth -= 1; index += 1; continue }
            if depth == 0, matchesAt(characters, index, markerCharacters) {
                let start = text.index(text.startIndex, offsetBy: index)
                let end = text.index(start, offsetBy: markerCharacters.count)
                return start..<end
            }
            index += 1
        }
        return nil
    }

    /// 顶层分隔（双竖线 / 双与号）
    static func splitTopLevel(_ text: String, separator: String) -> [String] {
        let separatorCharacters = Array(separator)
        let characters = Array(text)
        var results: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index += 1
                continue
            }
            if character == "[" || character == "(" || character == "{" {
                depth += 1
                current.append(character)
                index += 1
                continue
            }
            if character == "]" || character == ")" || character == "}" {
                depth -= 1
                current.append(character)
                index += 1
                continue
            }
            if depth == 0, matchesAt(characters, index, separatorCharacters) {
                results.append(current)
                current = ""
                index += separatorCharacters.count
                continue
            }
            current.append(character)
            index += 1
        }
        results.append(current)
        return results.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func matchesAt(_ characters: [Character], _ index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= characters.count else { return false }
        for offset in 0..<pattern.count where characters[index + offset] != pattern[offset] { return false }
        return true
    }

    /// 提取尖括号标签体（如 js 脚本块）
    static func extractTagBody(_ text: String, tag: String) -> String {
        let openTag = "<" + tag + ">"
        let close = "</" + tag + ">"
        if let openRange = text.range(of: openTag) {
            var body = String(text[openRange.upperBound...])
            if let closeRange = body.range(of: close) { body = String(body[..<closeRange.lowerBound]) }
            return body
        }
        if let start = text.firstIndex(of: ">") {
            var body = String(text[text.index(after: start)...])
            if let closeRange = body.range(of: close) { body = String(body[..<closeRange.lowerBound]) }
            return body
        }
        return text
    }
}
