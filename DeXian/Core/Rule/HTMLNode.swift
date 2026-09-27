import Foundation

/// 轻量 HTML DOM。
/// 自研解析器（不依赖第三方库）以便完全掌控 XPath 行为，
/// 并与 Legado/JSoup 的“容错式”解析保持一致。
final class HTMLNode {
    enum Kind {
        case document
        case element
        case text
        case comment
        /// 属性节点：XPath 的 attribute 轴用它参与求值
        case attribute
    }

    var kind: Kind
    /// 标签名（小写）；文本节点为空
    var name: String
    var attributes: [String: String]
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?
    /// 文本节点内容
    var text: String = ""
    /// 元素在源码中的原始 id（调试用）
    var elementID: ObjectIdentifier { ObjectIdentifier(self) }

    init(kind: Kind, name: String = "", attributes: [String: String] = [:], text: String = "") {
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    var isElement: Bool { kind == .element }
    var isText: Bool { kind == .text }
    var isAttribute: Bool { kind == .attribute }

    func append(_ node: HTMLNode) {
        node.parent = self
        children.append(node)
    }

    func attribute(_ key: String) -> String? {
        if let value = attributes[key] { return value }
        let lowered = key.lowercased()
        for (name, value) in attributes where name.lowercased() == lowered {
            return value
        }
        return nil
    }

    /// 构造属性节点（XPath attribute 轴使用）。
    func attributeNode(named key: String) -> HTMLNode? {
        guard kind == .element, let value = attribute(key) else { return nil }
        let node = HTMLNode(kind: .attribute, name: key, text: value)
        node.parent = self
        return node
    }

    var classList: [String] {
        (attribute("class") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    func hasClass(_ cls: String) -> Bool {
        classList.contains(cls)
    }

    /// 直接子文本（不含后代）
    var ownText: String {
        children.compactMap { $0.kind == .text ? $0.text : nil }.joined()
    }

    /// 全部后代文本（不做换行处理）
    var rawText: String {
        var buffer = ""
        collectText(into: &buffer)
        return buffer
    }

    private func collectText(into buffer: inout String) {
        if kind == .text || kind == .attribute {
            buffer += text
            return
        }
        for child in children { child.collectText(into: &buffer) }
    }

    /// 归一化文本：空白折叠，用于标题/作者这类短字段。
    var normalizedText: String {
        HTMLNode.normalizeWhitespace(rawText)
    }

    /// 带换行的文本：块级标签与 <br> 产生换行。
    /// 这是正文抽取的正确行为（保留段落）。
    var textWithBreaks: String {
        var buffer = ""
        appendTextWithBreaks(into: &buffer)
        return HTMLNode.collapseNewlines(buffer)
    }

    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6",
        "tr", "section", "article", "header", "footer", "blockquote",
        "pre", "dd", "dt", "ul", "ol", "table", "figure", "figcaption", "hr"
    ]

    private func appendTextWithBreaks(into buffer: inout String) {
        if kind == .text || kind == .attribute {
            buffer += text
            return
        }
        if kind == .comment { return }
        let isBlock = HTMLNode.blockTags.contains(name)
        if isBlock && !buffer.isEmpty && !buffer.hasSuffix("\n") { buffer += "\n" }
        if name == "br" || name == "hr" {
            buffer += "\n"
            return
        }
        for child in children { child.appendTextWithBreaks(into: &buffer) }
        if isBlock && !buffer.hasSuffix("\n") { buffer += "\n" }
    }

    /// outerHTML：把规则返回的元素序列化成 HTML 字符串
    /// （正文规则里返回 HTML 时，后续还要做 <img> 提取）。
    var outerHTML: String {
        switch kind {
        case .document:
            return children.map { $0.outerHTML }.joined()
        case .text, .attribute:
            return text
        case .comment:
            return "<!--\(text)-->"
        case .element:
            var buffer = "<\(name)"
            for (key, value) in attributes {
                buffer += " \(key)=\"\(value.replacingOccurrences(of: "\"", with: "&quot;"))\""
            }
            if HTMLNode.voidTags.contains(name) { return buffer + "/>" }
            buffer += ">"
            for child in children { buffer += child.outerHTML }
            buffer += "</\(name)>"
            return buffer
        }
    }

    var innerHTML: String {
        children.map { $0.outerHTML }.joined()
    }

    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    static func normalizeWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            // 只把 ASCII 空白当作可折叠空格：\u{00a0} / \u{3000} 等属于正文内容，必须保留
            let isSpace = scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
            if isSpace {
                if !lastWasSpace && !result.isEmpty { result.append(" ") }
                lastWasSpace = true
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    static func collapseNewlines(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            lines.append(trimLine(line))
        }
        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimLine(_ line: String) -> String {
        var value = line
        while let first = value.first, first == " " || first == "\t" || first == "\r" || first == "\u{00a0}" {
            value.removeFirst()
        }
        while let last = value.last, last == " " || last == "\t" || last == "\r" || last == "\u{00a0}" {
            value.removeLast()
        }
        return value
    }
}

/// 容错 HTML 解析器。
/// 处理：未闭合标签、void 元素、隐式闭合（p/li/td/tr 等）、
/// script/style 原始文本、注释、属性引号缺省。
enum HTMLParser {
    /// DOM 最大嵌套深度。超过后不再继续下钻，避免递归遍历栈溢出。
    static let maxDepth = 256

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(kind: .document)
        var stack: [HTMLNode] = [root]
        let characters = Array(html)
        let count = characters.count
        var index = 0

        var pendingText = ""
        // 因超过 maxDepth 而未入栈的标签名（按遇到顺序）。
        // 这些标签的子树直接挂在当前栈顶，深度因此有界；
        // 记录它们是为了让「结束标签」不要去弹真正的祖先，
        // 否则 <div> 嵌套超限时一个 </div> 会把整棵祖先树弹掉。
        var overflowTags: [String] = []
        func flushText() {
            guard !pendingText.isEmpty else { return }
            let node = HTMLNode(kind: .text, text: decodeEntities(pendingText))
            stack[stack.count - 1].append(node)
            pendingText = ""
        }

        while index < count {
            let char = characters[index]

            // 注释 / CDATA / doctype
            if char == "<" {
                if matches(characters, index, "<!--") {
                    flushText()
                    var end = index + 4
                    while end < count && !matches(characters, end, "-->") { end += 1 }
                    let content = String(characters[(index + 4)..<min(end, count)])
                    stack[stack.count - 1].append(HTMLNode(kind: .comment, text: content))
                    index = min(end + 3, count)
                    continue
                }
                if matches(characters, index, "<![CDATA[") {
                    flushText()
                    var end = index + 9
                    while end < count && !matches(characters, end, "]]>") { end += 1 }
                    pendingText += String(characters[(index + 9)..<min(end, count)])
                    index = min(end + 3, count)
                    continue
                }
                if matches(characters, index, "<!") {
                    flushText()
                    var end = index + 2
                    while end < count && characters[end] != ">" { end += 1 }
                    index = min(end + 1, count)
                    continue
                }
                if matches(characters, index, "</") {
                    flushText()
                    var cursor = index + 2
                    var name = ""
                    while cursor < count, isNameCharacter(characters[cursor]) {
                        name.append(characters[cursor])
                        cursor += 1
                    }
                    while cursor < count, characters[cursor] != ">" { cursor += 1 }
                    index = min(cursor + 1, count)
                    let closing = name.lowercased()
                    if let position = overflowTags.lastIndex(of: closing) {
                        // 属于被跳过的子树，只结算 overflow 记录
                        overflowTags.removeSubrange(position..<overflowTags.count)
                    } else {
                        closeTag(closing, stack: &stack)
                    }
                    continue
                }
                if index + 1 < count, isNameStart(characters[index + 1]) {
                    flushText()
                    var cursor = index + 1
                    var name = ""
                    while cursor < count, isNameCharacter(characters[cursor]) {
                        name.append(characters[cursor])
                        cursor += 1
                    }
                    let tagName = name.lowercased()
                    var attributes: [String: String] = [:]
                    var selfClosing = false

                    while cursor < count {
                        while cursor < count, characters[cursor].isWhitespace { cursor += 1 }
                        if cursor >= count { break }
                        if characters[cursor] == ">" { cursor += 1; break }
                        if characters[cursor] == "/" {
                            if cursor + 1 < count, characters[cursor + 1] == ">" {
                                selfClosing = true
                                cursor += 2
                                break
                            }
                            cursor += 1
                            continue
                        }
                        var attrName = ""
                        while cursor < count, isNameCharacter(characters[cursor]) {
                            attrName.append(characters[cursor])
                            cursor += 1
                        }
                        guard !attrName.isEmpty else { cursor += 1; continue }
                        while cursor < count, characters[cursor].isWhitespace { cursor += 1 }
                        var attrValue = ""
                        if cursor < count, characters[cursor] == "=" {
                            cursor += 1
                            while cursor < count, characters[cursor].isWhitespace { cursor += 1 }
                            if cursor < count, characters[cursor] == "\"" || characters[cursor] == "'" {
                                let quote = characters[cursor]
                                cursor += 1
                                var value = ""
                                while cursor < count, characters[cursor] != quote {
                                    value.append(characters[cursor])
                                    cursor += 1
                                }
                                if cursor < count { cursor += 1 }
                                attrValue = value
                            } else {
                                var value = ""
                                while cursor < count, !characters[cursor].isWhitespace,
                                      characters[cursor] != ">", characters[cursor] != "/" {
                                    value.append(characters[cursor])
                                    cursor += 1
                                }
                                attrValue = value
                            }
                        }
                        attributes[attrName.lowercased()] = decodeEntities(attrValue)
                    }

                    index = cursor
                    pendingText = "" // 文本已在 flushText 中入栈

                    let node = HTMLNode(kind: .element, name: tagName, attributes: attributes)
                    autoClose(tagName, stack: &stack)
                    stack[stack.count - 1].append(node)

                    if HTMLNode.voidTags.contains(tagName) || selfClosing {
                        continue
                    }
                    // 深度上限：真实网页里成千上万个未闭合的 <div>（广告位、
                    // 模板残缺）会把 DOM 堆到上万层，之后任何递归遍历
                    // （outerHTML / rawText / textWithBreaks）都会栈溢出闪退。
                    // 浏览器解析栈同样有上限，这里对齐成 256 层，超出即当作兄弟节点。
                    if stack.count >= HTMLParser.maxDepth {
                        // 不再入栈：子树留在当前栈顶，深度有界；
                        // 记下标签名，好让对应的结束标签被正确抵消。
                        overflowTags.append(tagName)
                        continue
                    }
                    if tagName == "script" || tagName == "style" {
                        // 原始文本元素：内容不解析标签
                        var raw = ""
                        let closeTag = "</\(tagName)"
                        while index < count {
                            if characters[index] == "<", matchesIgnoringCase(characters, index, closeTag) {
                                break
                            }
                            raw.append(characters[index])
                            index += 1
                        }
                        if !raw.isEmpty {
                            node.append(HTMLNode(kind: .text, text: raw))
                        }
                        // 跳过结束标签
                        var cursor = index
                        while cursor < count, characters[cursor] != ">" { cursor += 1 }
                        index = min(cursor + 1, count)
                        continue
                    }
                    stack.append(node)
                    continue
                }
            }

            pendingText.append(char)
            index += 1
        }
        flushText()
        return root
    }

    private static func isNameStart(_ char: Character) -> Bool {
        char.isLetter
    }

    private static func isNameCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "-" || char == "_" || char == ":"
    }

    private static func matches(_ characters: [Character], _ index: Int, _ pattern: String) -> Bool {
        let patternChars = Array(pattern)
        guard index + patternChars.count <= characters.count else { return false }
        for offset in 0..<patternChars.count where characters[index + offset] != patternChars[offset] {
            return false
        }
        return true
    }

    private static func matchesIgnoringCase(_ characters: [Character], _ index: Int, _ pattern: String) -> Bool {
        let patternChars = Array(pattern.lowercased())
        guard index + patternChars.count <= characters.count else { return false }
        for offset in 0..<patternChars.count {
            if Character(characters[index + offset].lowercased()) != patternChars[offset] { return false }
        }
        return true
    }

    /// 隐式闭合表：key = 新遇到的标签，value = 允许被它关闭的**栈顶**标签。
    ///
    /// 关键约束：value 里只能出现「不可能包含 key」的标签。
    /// 例如 <div>/<ul>/<table> 可以包含 <p>，所以它们能关闭栈顶的 <p>；
    /// 但容器类标签绝不能出现在自己的关闭集合里，
    /// 否则每遇一个新标签就会把祖先弹栈，整棵 DOM 树被摧毁。
    private static let implicitClose: [String: Set<String>] = [
        "p": ["p"],
        "div": ["p"],
        "section": ["p"],
        "article": ["p"],
        "blockquote": ["p"],
        "pre": ["p"],
        "ul": ["p"],
        "ol": ["p"],
        "table": ["p"],
        "figure": ["p"],
        "figcaption": ["p"],
        "dl": ["p"],
        "hr": ["p"],
        "form": ["p"],
        "fieldset": ["p"],
        "details": ["p"],
        "summary": ["p"],
        "address": ["p"],
        "center": ["p"],
        "menu": ["p"],
        "hgroup": ["p"],
        "header": ["p"],
        "footer": ["p"],
        "nav": ["p"],
        "aside": ["p"],
        "main": ["p"],
        "li": ["p", "li"],
        "dt": ["p", "dt", "dd"],
        "dd": ["p", "dt", "dd"],
        "td": ["p", "td", "th"],
        "th": ["p", "td", "th"],
        "tr": ["p", "tr", "td", "th"],
        "thead": ["p", "thead", "tbody", "tfoot", "tr", "td", "th"],
        "tbody": ["p", "thead", "tbody", "tfoot", "tr", "td", "th"],
        "tfoot": ["p", "thead", "tbody", "tfoot", "tr", "td", "th"],
        "option": ["option"],
        "h1": ["p", "h1", "h2", "h3", "h4", "h5", "h6"],
        "h2": ["p", "h1", "h2", "h3", "h4", "h5", "h6"],
        "h3": ["p", "h1", "h2", "h3", "h4", "h5", "h6"],
        "h4": ["p", "h1", "h2", "h3", "h4", "h5", "h6"],
        "h5": ["p", "h1", "h2", "h3", "h4", "h5", "h6"],
        "h6": ["p", "h1", "h2", "h3", "h4", "h5", "h6"]
    ]

    private static func autoClose(_ tagName: String, stack: inout [HTMLNode]) {
        if let triggers = implicitClose[tagName] {
            while stack.count > 1, triggers.contains(stack[stack.count - 1].name) {
                stack.removeLast()
            }
        }
    }

    private static func closeTag(_ name: String, stack: inout [HTMLNode]) {
        guard !name.isEmpty else { return }
        if let position = stack.lastIndex(where: { $0.name == name }), position > 0 {
            stack.removeSubrange(position..<stack.count)
        }
    }

    private static let entities: [String: String] = [
        "nbsp": "\u{00a0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
        "apos": "'", "copy": "©", "reg": "®", "hellip": "…", "mdash": "—",
        "ndash": "–", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "times": "×", "divide": "÷", "middot": "·", "bull": "•", "deg": "°",
        "laquo": "«", "raquo": "»", "sect": "§", "para": "¶", "dagger": "†",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "trade": "™",
        "ensp": " ", "emsp": " ", "thinsp": " ", "zwnj": "\u{200c}", "zwj": "\u{200d}",
        "shy": "\u{00ad}", "not": "¬", "sup2": "²", "sup3": "³", "frac12": "½",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "prime": "′"
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char != "&" {
                result.append(char)
                index += 1
                continue
            }
            var cursor = index + 1
            var entity = ""
            while cursor < characters.count, cursor - index <= 10, characters[cursor] != ";" {
                entity.append(characters[cursor])
                cursor += 1
            }
            if cursor < characters.count, characters[cursor] == ";", !entity.isEmpty {
                if entity.hasPrefix("#") {
                    let numberPart = String(entity.dropFirst())
                    var code: UInt32?
                    if numberPart.hasPrefix("x") || numberPart.hasPrefix("X") {
                        code = UInt32(numberPart.dropFirst(), radix: 16)
                    } else {
                        code = UInt32(numberPart)
                    }
                    if let code, let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                        index = cursor + 1
                        continue
                    }
                } else if let value = entities[entity.lowercased()] {
                    result += value
                    index = cursor + 1
                    continue
                }
            }
            result.append(char)
            index += 1
        }
        return result
    }
}
