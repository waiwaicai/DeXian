import Foundation

/// JSONPath 引擎：书源里 "$." 前缀的规则都走这里。
///
/// 支持 $.a.b、$..name 递归、[*]、[0]、[0,1]、[1:3]、['key']、
/// [?(expr)] 过滤（== != > < >= <= =~ && || 存在性判断）。
enum JSONPath {

    static func query(_ path: String, json: Any) -> [Any] {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@") { text = String(text.dropFirst()) }
        guard let expression = parse(text) else { return [] }
        return evaluate(expression, root: json)
    }

    // MARK: 表达式

    enum Segment {
        case child(String)
        case wildcard
        case recursiveChild(String)
        case recursiveWildcard
        case index(Int)
        case union([Int])
        case slice(Int?, Int?, Int)
        case filter(String)
    }

    struct PathExpression {
        var segments: [Segment]
    }

    // MARK: 解析

    static func parse(_ text: String) -> PathExpression? {
        var segments: [Segment] = []
        let characters = Array(text)
        var index = 0

        if index < characters.count, characters[index] == "$" { index += 1 }

        while index < characters.count {
            let character = characters[index]

            if character == "." {
                index += 1
                if index < characters.count, characters[index] == "." {
                    index += 1
                    if index < characters.count, characters[index] == "*" {
                        segments.append(.recursiveWildcard)
                        index += 1
                        continue
                    }
                    var name = ""
                    while index < characters.count, isNameCharacter(characters[index]) {
                        name.append(characters[index])
                        index += 1
                    }
                    if name.isEmpty { continue }
                    segments.append(.recursiveChild(name))
                    continue
                }
                if index < characters.count, characters[index] == "*" {
                    segments.append(.wildcard)
                    index += 1
                    continue
                }
                var name = ""
                while index < characters.count, isNameCharacter(characters[index]) {
                    name.append(characters[index])
                    index += 1
                }
                if name.isEmpty { continue }
                segments.append(.child(name))
                continue
            }

            if character == "[" {
                guard let (segment, nextIndex) = parseBracket(characters, from: index) else { return nil }
                segments.append(segment)
                index = nextIndex
                continue
            }

            if character == "*" {
                segments.append(.wildcard)
                index += 1
                continue
            }

            var name = ""
            while index < characters.count, isNameCharacter(characters[index]) {
                name.append(characters[index])
                index += 1
            }
            if name.isEmpty { index += 1; continue }
            segments.append(.child(name))
        }

        return PathExpression(segments: segments)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private static func parseBracket(_ characters: [Character], from start: Int) -> (Segment, Int)? {
        var index = start + 1
        var depth = 1
        var content = ""
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                content.append(character)
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                content.append(character)
                index += 1
                continue
            }
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            content.append(character)
            index += 1
        }
        guard index < characters.count else { return nil }
        index += 1

        let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("?") {
            var expression = String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if expression.hasPrefix("("), expression.hasSuffix(")") {
                expression = String(expression.dropFirst().dropLast())
            }
            return (.filter(expression), index)
        }

        if raw.hasPrefix("'") || raw.hasPrefix("\"") {
            return (.child(stripQuotes(raw)), index)
        }

        if raw == "*" { return (.wildcard, index) }

        if raw.contains(":") {
            let parts = raw.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }
            let startValue = Int(parts[0].trimmingCharacters(in: .whitespaces))
            let endValue = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            let stepRaw = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespaces)) : nil
            var step = stepRaw ?? 1
            if step == 0 { step = 1 }
            return (.slice(startValue, endValue, step), index)
        }

        if raw.contains(",") {
            let values = raw.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (.union(values), index)
        }

        if let value = Int(raw) { return (.index(value), index) }

        return (.child(stripQuotes(raw)), index)
    }

    private static func stripQuotes(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: 求值

    static func evaluate(_ expression: PathExpression, root: Any) -> [Any] {
        var current: [Any] = [root]
        for segment in expression.segments {
            var next: [Any] = []
            for item in current {
                next.append(contentsOf: apply(segment, to: item))
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    private static func apply(_ segment: Segment, to item: Any) -> [Any] {
        switch segment {
        case .child(let name):
            if let dictionary = item as? [String: Any], let value = dictionary[name] { return [value] }
            return []

        case .wildcard:
            if let dictionary = item as? [String: Any] { return Array(dictionary.values) }
            if let array = item as? [Any] { return array }
            return []

        case .recursiveChild(let name):
            var results: [Any] = []
            collectRecursive(item: item, key: name, into: &results)
            return results

        case .recursiveWildcard:
            var results: [Any] = []
            collectAllDescendants(item: item, into: &results)
            return results

        case .index(let value):
            guard let array = item as? [Any] else { return [] }
            let resolved = value < 0 ? array.count + value : value
            guard resolved >= 0, resolved < array.count else { return [] }
            return [array[resolved]]

        case .union(let values):
            guard let array = item as? [Any] else { return [] }
            var results: [Any] = []
            for value in values {
                let resolved = value < 0 ? array.count + value : value
                if resolved >= 0, resolved < array.count { results.append(array[resolved]) }
            }
            return results

        case .slice(let start, let end, let step):
            guard let array = item as? [Any] else { return [] }
            let count = array.count
            var lower = start ?? 0
            var upper = end ?? count
            if lower < 0 { lower += count }
            if upper < 0 { upper += count }
            lower = max(0, min(lower, count))
            upper = max(0, min(upper, count))
            var results: [Any] = []
            if step > 0 {
                var cursor = lower
                while cursor < upper {
                    results.append(array[cursor])
                    cursor += step
                }
            } else {
                var cursor = min(lower, count - 1)
                while cursor > upper, cursor >= 0 {
                    results.append(array[cursor])
                    cursor += step
                }
            }
            return results

        case .filter(let expression):
            var items: [Any] = []
            if let array = item as? [Any] {
                items = array
            } else if let dictionary = item as? [String: Any] {
                items = [dictionary]
            }
            let evaluator = FilterEvaluator(expression: expression)
            return items.filter { evaluator.evaluate(item: $0) }
        }
    }

    private static func collectRecursive(item: Any, key: String, into results: inout [Any]) {
        if let dictionary = item as? [String: Any] {
            if let value = dictionary[key] { results.append(value) }
            for value in dictionary.values { collectRecursive(item: value, key: key, into: &results) }
            return
        }
        if let array = item as? [Any] {
            for value in array { collectRecursive(item: value, key: key, into: &results) }
        }
    }

    private static func collectAllDescendants(item: Any, into results: inout [Any]) {
        if let dictionary = item as? [String: Any] {
            for value in dictionary.values {
                results.append(value)
                collectAllDescendants(item: value, into: &results)
            }
            return
        }
        if let array = item as? [Any] {
            for value in array {
                results.append(value)
                collectAllDescendants(item: value, into: &results)
            }
        }
    }

    // MARK: 过滤表达式

    struct FilterEvaluator {
        let expression: String

        func evaluate(item: Any) -> Bool {
            var parser = FilterParser(expression: expression, item: item)
            return parser.parseOr()
        }
    }

    struct FilterParser {
        let tokens: [FilterToken]
        let item: Any
        var index = 0

        init(expression: String, item: Any) {
            var lexer = FilterLexer(expression: expression)
            tokens = lexer.tokenize()
            self.item = item
        }

        private var current: FilterToken? { index < tokens.count ? tokens[index] : nil }

        mutating func advance() -> FilterToken? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        mutating func parseOr() -> Bool {
            var value = parseAnd()
            while case .or? = current {
                _ = advance()
                let right = parseAnd()
                value = value || right
            }
            return value
        }

        mutating func parseAnd() -> Bool {
            var value = parseComparison()
            while case .and? = current {
                _ = advance()
                let right = parseComparison()
                value = value && right
            }
            return value
        }

        mutating func parseComparison() -> Bool {
            let left = parseOperand()
            guard let token = current else { return truthy(left) }
            switch token {
            case .equal, .notEqual, .greater, .less, .greaterOrEqual, .lessOrEqual, .regexMatch, .regexNotMatch:
                _ = advance()
                let right = parseOperand()
                return compare(left: left, right: right, op: token)
            default:
                return truthy(left)
            }
        }

        mutating func parseOperand() -> FilterValue {
            guard let token = advance() else { return .missing }
            switch token {
            case .atPath(let path), .rootPath(let path):
                return resolve(path: path, base: item)
            case .literal(let value):
                return .value(value)
            case .numberLiteral(let value):
                return .value(value)
            case .boolLiteral(let value):
                return .value(value)
            case .nullLiteral:
                return .value(NSNull())
            case .leftParen:
                return parseGrouped()
            default:
                return .missing
            }
        }

        mutating func parseGrouped() -> FilterValue {
            let left = parseOperand()
            var result = left
            while let token = current {
                switch token {
                case .equal, .notEqual, .greater, .less, .greaterOrEqual, .lessOrEqual, .regexMatch, .regexNotMatch:
                    _ = advance()
                    let right = parseOperand()
                    result = .value(compare(left: left, right: right, op: token))
                case .rightParen:
                    _ = advance()
                    return result
                default:
                    _ = advance()
                }
            }
            return result
        }

        private func resolve(path: String, base: Any) -> FilterValue {
            let value = JSONPath.query("$" + path, json: base)
            guard let first = value.first else { return .missing }
            return .value(first)
        }

        private func truthy(_ value: FilterValue) -> Bool {
            switch value {
            case .missing:
                return false
            case .value(let raw):
                if let bool = raw as? Bool { return bool }
                if raw is NSNull { return false }
                if let number = RuleUtil.asDouble(raw) { return number != 0 }
                if let text = raw as? String { return !text.isEmpty }
                return true
            }
        }

        private func compare(left: FilterValue, right: FilterValue, op: FilterToken) -> Bool {
            if case .missing = left { return op == .notEqual }
            if case .missing = right { return op == .notEqual }
            guard case .value(let lhs) = left, case .value(let rhs) = right else { return false }

            switch op {
            case .regexMatch, .regexNotMatch:
                let pattern = RuleUtil.asString(rhs) ?? ""
                let text = RuleUtil.asString(lhs) ?? ""
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                let matched = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                return op == .regexMatch ? matched : !matched
            case .equal, .notEqual:
                let isEqual = looseEquals(lhs, rhs)
                return op == .equal ? isEqual : !isEqual
            default:
                let lhsNumber = RuleUtil.asDouble(lhs)
                let rhsNumber = RuleUtil.asDouble(rhs)
                if RuleUtil.isNumeric(lhs), RuleUtil.isNumeric(rhs), let lhsNumber, let rhsNumber {
                    switch op {
                    case .greater: return lhsNumber > rhsNumber
                    case .less: return lhsNumber < rhsNumber
                    case .greaterOrEqual: return lhsNumber >= rhsNumber
                    case .lessOrEqual: return lhsNumber <= rhsNumber
                    default: return false
                    }
                }
                let lhsText = RuleUtil.asString(lhs) ?? ""
                let rhsText = RuleUtil.asString(rhs) ?? ""
                switch op {
                case .greater: return lhsText > rhsText
                case .less: return lhsText < rhsText
                case .greaterOrEqual: return lhsText >= rhsText
                case .lessOrEqual: return lhsText <= rhsText
                default: return false
                }
            }
        }

        private func looseEquals(_ lhs: Any, _ rhs: Any) -> Bool {
            if lhs is NSNull, rhs is NSNull { return true }
            if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool { return lhsBool == rhsBool }
            if RuleUtil.isNumeric(lhs), RuleUtil.isNumeric(rhs),
               let lhsNumber = RuleUtil.asDouble(lhs), let rhsNumber = RuleUtil.asDouble(rhs) {
                return lhsNumber == rhsNumber
            }
            return (RuleUtil.asString(lhs) ?? "") == (RuleUtil.asString(rhs) ?? "")
        }
    }

    enum FilterValue {
        case value(Any)
        case missing
    }

    enum FilterToken: Equatable {
        case atPath(String)
        case rootPath(String)
        case literal(String)
        case numberLiteral(Double)
        case boolLiteral(Bool)
        case nullLiteral
        case equal
        case notEqual
        case greater
        case less
        case greaterOrEqual
        case lessOrEqual
        case regexMatch
        case regexNotMatch
        case and
        case or
        case leftParen
        case rightParen
    }

    struct FilterLexer {
        let expression: String
        private var characters: [Character] = []
        private var index = 0

        init(expression: String) {
            self.expression = expression
            characters = Array(expression)
        }

        mutating func tokenize() -> [FilterToken] {
            var tokens: [FilterToken] = []
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace { index += 1; continue }

                if character == "@" || character == "$" {
                    let marker = character
                    index += 1
                    var path = ""
                    var depth = 0
                    while index < characters.count {
                        let current = characters[index]
                        if current == "(" { depth += 1 }
                        if current == ")" {
                            if depth == 0 { break }
                            depth -= 1
                        }
                        if depth == 0, current == "&" || current == "|" || current == ")"
                            || current == "=" || current == "<" || current == ">" || current == "!" {
                            break
                        }
                        path.append(current)
                        index += 1
                    }
                    let trimmedPath = path.trimmingCharacters(in: .whitespaces)
                    tokens.append(marker == "@" ? .atPath(trimmedPath) : .rootPath(trimmedPath))
                    continue
                }

                if character == "(" { tokens.append(.leftParen); index += 1; continue }
                if character == ")" { tokens.append(.rightParen); index += 1; continue }

                if character == "&" {
                    index += (index + 1 < characters.count && characters[index + 1] == "&") ? 2 : 1
                    tokens.append(.and)
                    continue
                }
                if character == "|" {
                    index += (index + 1 < characters.count && characters[index + 1] == "|") ? 2 : 1
                    tokens.append(.or)
                    continue
                }

                if character == "=" {
                    if index + 1 < characters.count, characters[index + 1] == "~" {
                        tokens.append(.regexMatch); index += 2
                    } else if index + 1 < characters.count, characters[index + 1] == "=" {
                        tokens.append(.equal); index += 2
                    } else {
                        tokens.append(.equal); index += 1
                    }
                    continue
                }
                if character == "!" {
                    if index + 1 < characters.count, characters[index + 1] == "~" {
                        tokens.append(.regexNotMatch); index += 2
                    } else if index + 1 < characters.count, characters[index + 1] == "=" {
                        tokens.append(.notEqual); index += 2
                    } else {
                        tokens.append(.notEqual); index += 1
                    }
                    continue
                }
                if character == ">" {
                    if index + 1 < characters.count, characters[index + 1] == "=" {
                        tokens.append(.greaterOrEqual); index += 2
                    } else {
                        tokens.append(.greater); index += 1
                    }
                    continue
                }
                if character == "<" {
                    if index + 1 < characters.count, characters[index + 1] == "=" {
                        tokens.append(.lessOrEqual); index += 2
                    } else {
                        tokens.append(.less); index += 1
                    }
                    continue
                }

                if character == "'" || character == "\"" {
                    let quote = character
                    index += 1
                    var value = ""
                    while index < characters.count, characters[index] != quote {
                        if characters[index] == "\\", index + 1 < characters.count { index += 1 }
                        value.append(characters[index])
                        index += 1
                    }
                    if index < characters.count { index += 1 }
                    tokens.append(.literal(value))
                    continue
                }

                if character == "/" {
                    index += 1
                    var value = ""
                    while index < characters.count, characters[index] != "/" {
                        if characters[index] == "\\", index + 1 < characters.count {
                            value.append(characters[index])
                            index += 1
                        }
                        value.append(characters[index])
                        index += 1
                    }
                    if index < characters.count { index += 1 }
                    while index < characters.count, characters[index].isLetter { index += 1 }
                    tokens.append(.literal(value))
                    continue
                }

                if character.isNumber || character == "-" {
                    var value = ""
                    if character == "-" {
                        value.append(character)
                        index += 1
                    }
                    var hasDot = false
                    while index < characters.count {
                        let current = characters[index]
                        if current.isNumber { value.append(current); index += 1; continue }
                        if current == ".", !hasDot { hasDot = true; value.append(current); index += 1; continue }
                        break
                    }
                    tokens.append(.numberLiteral(Double(value) ?? 0))
                    continue
                }

                if character.isLetter || character == "_" {
                    var value = ""
                    while index < characters.count,
                          characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                        value.append(characters[index])
                        index += 1
                    }
                    switch value.lowercased() {
                    case "true": tokens.append(.boolLiteral(true))
                    case "false": tokens.append(.boolLiteral(false))
                    case "null": tokens.append(.nullLiteral)
                    case "and": tokens.append(.and)
                    case "or": tokens.append(.or)
                    default: tokens.append(.literal(value))
                    }
                    continue
                }

                index += 1
            }
            return tokens
        }
    }
}
