import Foundation

/// Legado「默认规则」选择器（Jsoup 风格）。
///
/// yckceo / 源仓库里的书源大量使用这种写法：
/// `class.item.0@tag.a@href`、`tag.tr[1:]`、`id.list-chapterAll@tag.dd`、`text.下一页@href`。
/// 它与标准 CSS 的差别在于类型前缀和位置索引：
/// 直接丢给 CSS 选择器会一条都匹配不到，因此单独实现一套求值。
enum LegacySelector {

    /// 位置筛选：单个索引或区间（两端与步长都支持负数）。
    enum Index {
        case single(Int)
        case range(Int?, Int?, Int)
    }

    /// 是否是传统选择器规则。
    static func isLegacy(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if value == "children" || value.hasPrefix("children.") || value.hasPrefix("children[") {
            return true
        }
        for prefix in ["class.", "tag.", "id.", "text."] where value.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// 求值：返回匹配节点（按文档顺序去重）。
    static func select(_ rule: String, in root: HTMLNode) -> [HTMLNode] {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var reversed = false
        if text.hasPrefix("-") {
            reversed = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return [] }

        let parsed = parse(text)
        guard !parsed.rule.isEmpty else { return [] }

        let selector = selectorName(parsed.rule)
        var elements = baseElements(prefix: selector.prefix, value: selector.value,
                                    rule: parsed.rule, in: root)
        if !parsed.indexes.isEmpty {
            elements = apply(parsed.indexes, to: elements, exclusion: parsed.exclusion)
        }
        if reversed { elements.reverse() }
        return elements
    }

    // MARK: 规则解析

    private struct Parsed {
        var rule: String
        var indexes: [Index] = []
        var exclusion = false
    }

    /// 拆出「选择器主体」与「位置筛选」，位置筛选支持 `[1:3]` 与 `.0` / `!0:3` 两种写法。
    private static func parse(_ text: String) -> Parsed {
        // 方括号写法：tag.tr[1:] / tag.a[-1:0] / tag.div[!0:3]
        if text.hasSuffix("]"), let open = lastTopLevelIndex(of: "[", in: text) {
            let content = String(text[text.index(after: open)...].dropLast())
            let rule = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            let items = parseBracketContent(content)
            return Parsed(rule: rule, indexes: items.indexes, exclusion: items.exclusion)
        }

        // 传统写法：tag.span.0 / class.book.1:3 / tag.div!0:3
        let characters = Array(text)
        var end = characters.count
        while end > 0, characters[end - 1] == " " { end -= 1 }
        var cursor = end
        while cursor > 0 {
            let character = characters[cursor - 1]
            if character.isNumber || character == "-" || character == ":" { cursor -= 1; continue }
            break
        }
        if cursor < end, cursor > 0, characters[cursor - 1] == "." || characters[cursor - 1] == "!" {
            let separator = characters[cursor - 1]
            let body = String(characters[cursor..<end])
            if let indexes = parseIndexList(body) {
                return Parsed(rule: text, indexes: indexes, exclusion: separator == "!")
            }
        }
        return Parsed(rule: text)
    }

    private static func parseBracketContent(_ content: String) -> (indexes: [Index], exclusion: Bool) {
        var body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var exclusion = false
        if body.hasPrefix("!") {
            exclusion = true
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        var indexes: [Index] = []
        for piece in body.split(separator: ",") {
            let item = piece.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let parts = item.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch parts.count {
            case 1:
                if let value = Int(parts[0]) { indexes.append(.single(value)) }
            case 2:
                if let start = parts[0].isEmpty ? 0 : Int(parts[0]),
                   let end = parts[1].isEmpty ? nil : Int(parts[1]) {
                    indexes.append(.range(start, end, 1))
                }
            default:
                if let start = parts[0].isEmpty ? 0 : Int(parts[0]),
                   let end = parts[1].isEmpty ? nil : Int(parts[1]),
                   let step = parts[2].isEmpty ? 1 : Int(parts[2]) {
                    indexes.append(.range(start, end, step))
                }
            }
        }
        return (indexes, exclusion)
    }

    private static func parseIndexList(_ body: String) -> [Index]? {
        var indexes: [Index] = []
        for piece in body.split(separator: ":") {
            let item = piece.trimmingCharacters(in: .whitespaces)
            guard let value = Int(item) else { return nil }
            indexes.append(.single(value))
        }
        return indexes.isEmpty ? nil : indexes
    }

    /// 从主体里取出类型前缀与名称。
    ///
    /// 名称按第一个点号截断，与 Legado 的 `split(".")[1]` 对齐；
    /// 这样 `class.x-book__coverbox.0` 之类的残缺写法也能取到真正类名。
    private static func selectorName(_ rule: String) -> (prefix: String, value: String) {
        let lowered = rule.lowercased()
        if lowered.hasPrefix("children") {
            return ("children", "")
        }
        for prefix in ["class", "tag", "id", "text"] where lowered.hasPrefix(prefix + ".") {
            let start = rule.index(rule.startIndex, offsetBy: prefix.count + 1)
            let part = String(rule[start...])
            let name = part.split(separator: ".").first.map(String.init) ?? ""
            return (prefix, name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ("css", rule)
    }

    // MARK: 取元素

    private static func baseElements(prefix: String, value: String, rule: String, in root: HTMLNode) -> [HTMLNode] {
        switch prefix {
        case "children":
            return root.children.filter { $0.isElement }
        case "class":
            guard !value.isEmpty else { return [] }
            let tokens = value.split(separator: " ").map(String.init)
            return allElements(in: root).filter { node in
                let classes = node.classList
                for token in tokens where !classes.contains(token) { return false }
                return !tokens.isEmpty
            }
        case "tag":
            guard !value.isEmpty else { return [] }
            let wanted = value.lowercased()
            return allElements(in: root).filter { $0.name.lowercased() == wanted }
        case "id":
            guard !value.isEmpty else { return [] }
            return allElements(in: root).filter { $0.attribute("id") == value }
        case "text":
            guard !value.isEmpty else { return [] }
            return allElements(in: root).filter { $0.ownText.contains(value) }
        default:
            return CSSSelector.select(rule, in: root)
        }
    }

    /// 包含根节点自身在内的全部元素。
    private static func allElements(in root: HTMLNode) -> [HTMLNode] {
        var result: [HTMLNode] = []
        var stack: [HTMLNode] = [root]
        while let node = stack.popLast() {
            if node.isElement { result.append(node) }
            stack.append(contentsOf: node.children.reversed())
        }
        if root.isElement {
            // 深度优先顺序已天然满足；root 已在结果里
            return result
        }
        return result
    }

    // MARK: 位置筛选

    private static func apply(_ indexes: [Index], to elements: [HTMLNode], exclusion: Bool) -> [HTMLNode] {
        let count = elements.count
        var picked = Set<Int>()
        for index in indexes {
            switch index {
            case .single(let value):
                if let resolved = resolve(value, count: count) { picked.insert(resolved) }
            case .range(let start, let end, let step):
                for position in expand(start: start, end: end, step: step, count: count) {
                    picked.insert(position)
                }
            }
        }
        if exclusion {
            return elements.enumerated().filter { !picked.contains($0.offset) }.map { $0.element }
        }
        return picked.sorted().compactMap { count > $0 ? elements[$0] : nil }
    }

    private static func resolve(_ index: Int, count: Int) -> Int? {
        if index >= 0 { return index < count ? index : nil }
        let value = count + index
        return value >= 0 ? value : nil
    }

    private static func expand(start: Int?, end: Int?, step: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let from = resolve(start ?? 0, count: count) ?? (start ?? 0 < 0 ? 0 : count - 1)
        let to = resolve(end ?? (count - 1), count: count) ?? (count - 1)
        let rawStep = step == 0 ? 1 : step
        let magnitude = max(1, abs(rawStep) % count == 0 ? 1 : abs(rawStep))
        if from == to { return [from] }
        var result: [Int] = []
        if from < to {
            var value = from
            while value <= to { result.append(value); value += magnitude }
        } else {
            var value = from
            while value >= to { result.append(value); value -= magnitude }
        }
        return result
    }

    private static func lastTopLevelIndex(of character: Character, in text: String) -> String.Index? {
        var index = text.endIndex
        var quote: Character?
        while index > text.startIndex {
            index = text.index(before: index)
            let current = text[index]
            if let active = quote {
                if current == active { quote = nil }
                continue
            }
            if current == "'" || current == "\"" { quote = current; continue }
            if current == character { return index }
        }
        return nil
    }
}
