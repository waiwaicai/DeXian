import Foundation

/// CSS 选择器引擎（含 Legado/Jsoup 常用扩展伪类）。
/// 书源默认规则（@@）就是 CSS，因此这里是主力选择器。
enum CSSSelector {

    /// 查询匹配节点。
    static func select(_ selector: String, in root: HTMLNode) -> [HTMLNode] {
        let groups = splitGroups(selector)
        var result: [HTMLNode] = []
        for group in groups {
            let sequence = parseSequence(group)
            guard !sequence.compound.isEmpty else { continue }
            result.append(contentsOf: match(sequence, in: root))
        }
        return dedupeInDocumentOrder(result, root: root)
    }

    /// 元素自身是否匹配选择器（用于 :not 等）。
    static func matches(_ selector: String, element: HTMLNode) -> Bool {
        guard element.isElement else { return false }
        let groups = splitGroups(selector)
        for group in groups {
            let sequence = parseSequence(group)
            guard !sequence.compound.isEmpty else { continue }
            let compound = sequence.compound[sequence.compound.count - 1]
            if matchesCompound(compound, element: element) { return true }
        }
        return false
    }

    // MARK: 结构

    private struct Sequence {
        /// 复合选择器链，按从祖先到自身顺序
        var compound: [Compound] = []
        /// 每段之间的组合符（长度 = compound.count - 1）
        var combinators: [Character] = []
    }

    private struct Compound {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attributes: [AttributeSelector] = []
        var pseudos: [Pseudo] = []
        var universal = false
    }

    private struct AttributeSelector {
        var name: String
        var op: String?      // nil, "=", "^=", "$=", "*=", "~=", "|=", "!="
        var value: String?
    }

    private enum Pseudo {
        case firstChild
        case lastChild
        case onlyChild
        case nthChild(Int, Int)      // a, b  => an+b
        case firstOfType
        case lastOfType
        case not(String)
        case contains(String)
        case eq(Int)
        case empty
        case root
        case has(String)
    }

    // MARK: 解析

    private static func splitGroups(_ selector: String) -> [String] {
        var groups: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in selector {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "(", "[":
                depth += 1
                current.append(character)
            case ")", "]":
                depth -= 1
                current.append(character)
            case ",":
                if depth == 0 {
                    groups.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            default:
                current.append(character)
            }
        }
        if !current.trimmed.isEmpty { groups.append(current) }
        return groups
    }

    private static func parseSequence(_ text: String) -> Sequence {
        var sequence = Sequence()
        var buffer = ""
        var pendingCombinator: Character = " "
        var index = text.startIndex
        var depth = 0
        var quote: Character?

        func flush() {
            let piece = buffer.trimmed
            buffer = ""
            guard !piece.isEmpty else { return }
            if let compound = parseCompound(piece) {
                if !sequence.compound.isEmpty {
                    sequence.combinators.append(pendingCombinator)
                }
                sequence.compound.append(compound)
                pendingCombinator = " "
            }
        }

        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                buffer.append(character)
                if character == activeQuote { quote = nil }
                index = text.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                buffer.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "(" || character == "[" {
                depth += 1
                buffer.append(character)
                index = text.index(after: index)
                continue
            }
            if character == ")" || character == "]" {
                depth -= 1
                buffer.append(character)
                index = text.index(after: index)
                continue
            }
            if depth == 0, character == ">" || character == "+" || character == "~" {
                flush()
                pendingCombinator = character
                index = text.index(after: index)
                continue
            }
            if depth == 0, character.isWhitespace {
                flush()
                index = text.index(after: index)
                // 跳过连续空白
                while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                // 后面紧跟组合符时以组合符为准
                if index < text.endIndex, text[index] == ">" || text[index] == "+" || text[index] == "~" {
                    pendingCombinator = text[index]
                    index = text.index(after: index)
                    while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                }
                continue
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        return sequence
    }

    private static func parseCompound(_ text: String) -> Compound? {
        var compound = Compound()
        let characters = Array(text)
        var index = 0

        if index < characters.count, characters[index] == "*" {
            compound.universal = true
            index += 1
        } else if index < characters.count, isIdentifierStart(characters[index]) {
            var tag = ""
            while index < characters.count, isIdentifierCharacter(characters[index]) {
                tag.append(characters[index])
                index += 1
            }
            compound.tag = tag.lowercased()
        }

        while index < characters.count {
            let character = characters[index]
            if character == "#" {
                index += 1
                var value = ""
                while index < characters.count, isIdentifierCharacter(characters[index]) {
                    value.append(characters[index])
                    index += 1
                }
                compound.id = value
                continue
            }
            if character == "." {
                index += 1
                var value = ""
                while index < characters.count, isIdentifierCharacter(characters[index]) {
                    value.append(characters[index])
                    index += 1
                }
                compound.classes.append(value)
                continue
            }
            if character == "[" {
                var depth = 1
                var content = ""
                index += 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "[" { depth += 1 }
                    if characters[index] == "]" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    content.append(characters[index])
                    index += 1
                }
                index += 1
                if let attribute = parseAttribute(content) {
                    compound.attributes.append(attribute)
                }
                continue
            }
            if character == ":" {
                index += 1
                var isDouble = false
                if index < characters.count, characters[index] == ":" {
                    isDouble = true
                    index += 1
                }
                var name = ""
                while index < characters.count, isIdentifierCharacter(characters[index]) {
                    name.append(characters[index])
                    index += 1
                }
                var argument: String?
                if index < characters.count, characters[index] == "(" {
                    var depth = 1
                    var content = ""
                    index += 1
                    var quote: Character?
                    while index < characters.count, depth > 0 {
                        let current = characters[index]
                        if let activeQuote = quote {
                            if current == activeQuote { quote = nil }
                            content.append(current)
                            index += 1
                            continue
                        }
                        if current == "'" || current == "\"" {
                            quote = current
                            content.append(current)
                            index += 1
                            continue
                        }
                        if current == "(" { depth += 1 }
                        if current == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        content.append(current)
                        index += 1
                    }
                    index += 1
                    argument = content
                }
                if isDouble {
                    // ::text / ::attr 之类，Legado 不使用，忽略但记录
                    continue
                }
                if let pseudo = parsePseudo(name: name.lowercased(), argument: argument) {
                    compound.pseudos.append(pseudo)
                }
                continue
            }
            index += 1
        }
        return compound
    }

    private static func parseAttribute(_ content: String) -> AttributeSelector? {
        let text = content.trimmed
        guard !text.isEmpty else { return nil }
        let operators = ["!=", "^=", "$=", "*=", "~=", "|=", "="]
        for op in operators {
            if let range = text.range(of: op) {
                let name = String(text[..<range.lowerBound]).trimmed
                var value = String(text[range.upperBound...]).trimmed
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                return AttributeSelector(name: name.lowercased(), op: op, value: value)
            }
        }
        return AttributeSelector(name: text.lowercased(), op: nil, value: nil)
    }

    private static func parsePseudo(name: String, argument: String?) -> Pseudo? {
        switch name {
        case "first-child": return .firstChild
        case "last-child": return .lastChild
        case "only-child": return .onlyChild
        case "first-of-type": return .firstOfType
        case "last-of-type": return .lastOfType
        case "empty": return .empty
        case "root": return .root
        case "contains":
            guard let argument else { return nil }
            return .contains(unquote(argument))
        case "eq":
            guard let argument, let value = Int(argument.trimmed) else { return nil }
            return .eq(value)
        case "not":
            guard let argument else { return nil }
            return .not(argument)
        case "has":
            guard let argument else { return nil }
            return .has(argument)
        case "nth-child":
            guard let argument else { return nil }
            return parseNth(argument).map { Pseudo.nthChild($0.0, $0.1) }
        default:
            return nil
        }
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmed
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// 解析 an+b 表达式
    private static func parseNth(_ text: String) -> (Int, Int)? {
        var value = text.lowercased().replacingOccurrences(of: " ", with: "")
        if value == "odd" { return (2, 1) }
        if value == "even" { return (2, 0) }
        if let single = Int(value) { return (0, single) }
        guard let position = value.firstIndex(of: "n") else { return nil }
        let coefficientText = String(value[..<position])
        var remainderText = String(value[value.index(after: position)...])
        let coefficient: Int
        if coefficientText.isEmpty || coefficientText == "+" {
            coefficient = 1
        } else if coefficientText == "-" {
            coefficient = -1
        } else {
            coefficient = Int(coefficientText) ?? 1
        }
        remainderText = remainderText.replacingOccurrences(of: "+", with: "")
        let remainder = remainderText.isEmpty ? 0 : (Int(remainderText) ?? 0)
        return (coefficient, remainder)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "\\"
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "\\"
    }

    // MARK: 匹配

    private static func match(_ sequence: Sequence, in root: HTMLNode) -> [HTMLNode] {
        let lastIndex = sequence.compound.count - 1
        // 从最后一个复合选择器开始，反向回溯组合符
        var candidates = allElements(in: root)
        var result: [HTMLNode] = []
        for candidate in candidates {
            if matchesSequenceRightToLeft(sequence, index: lastIndex, element: candidate) {
                result.append(candidate)
            }
        }
        candidates = []
        return result
    }

    private static func matchesSequenceRightToLeft(_ sequence: Sequence, index: Int, element: HTMLNode) -> Bool {
        guard matchesCompound(sequence.compound[index], element: element) else { return false }
        if index == 0 { return true }
        // 组合符表长度理论上恒等于 compound.count - 1，但只要有任何一条
        // 选择器解析出「复合段比组合符多」的中间态，这里的 index - 1 就会
        // 变成 -1 并以数组越界陷阱（SIGABRT）直接终止进程 ——
        // 这种崩溃发生在 JS 回调触发的规则求值里，用户只看到搜索到一半闪退。
        // 这里显式做边界判断，越界按「后代」处理，语义与缺少组合符时一致。
        guard index - 1 < sequence.combinators.count else {
            var cursor = element.parent
            while let current = cursor {
                if current.isElement, matchesSequenceRightToLeft(sequence, index: index - 1, element: current) {
                    return true
                }
                cursor = current.parent
            }
            return false
        }
        let combinator = sequence.combinators[index - 1]
        switch combinator {
        case ">":
            guard let parent = element.parent, parent.isElement else { return false }
            return matchesSequenceRightToLeft(sequence, index: index - 1, element: parent)
        case "+":
            guard let previous = previousElementSibling(of: element) else { return false }
            return matchesSequenceRightToLeft(sequence, index: index - 1, element: previous)
        case "~":
            var cursor = previousElementSibling(of: element)
            while let current = cursor {
                if matchesSequenceRightToLeft(sequence, index: index - 1, element: current) { return true }
                cursor = previousElementSibling(of: current)
            }
            return false
        default:
            // 后代：任一祖先匹配
            var cursor = element.parent
            while let current = cursor {
                if current.isElement, matchesSequenceRightToLeft(sequence, index: index - 1, element: current) {
                    return true
                }
                cursor = current.parent
            }
            return false
        }
    }

    private static func matchesCompound(_ compound: Compound, element: HTMLNode) -> Bool {
        guard element.isElement else { return false }

        if let tag = compound.tag, element.name != tag { return false }
        if let id = compound.id, element.attribute("id") != id { return false }
        for cls in compound.classes where !element.hasClass(cls) { return false }

        for attribute in compound.attributes {
            let actual = element.attribute(attribute.name)
            guard let op = attribute.op else {
                if actual == nil { return false }
                continue
            }
            let expected = attribute.value ?? ""
            guard let actual else {
                if op == "!=" { continue }
                return false
            }
            switch op {
            case "=": if actual != expected { return false }
            case "!=": if actual == expected { return false }
            case "^=": if !actual.hasPrefix(expected) { return false }
            case "$=": if !actual.hasSuffix(expected) { return false }
            case "*=": if !actual.contains(expected) { return false }
            case "~=":
                let tokens = actual.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if !tokens.contains(expected) { return false }
            case "|=":
                if actual != expected, !actual.hasPrefix(expected + "-") { return false }
            default:
                break
            }
        }

        for pseudo in compound.pseudos where !matchesPseudo(pseudo, element: element) {
            return false
        }
        return true
    }

    private static func matchesPseudo(_ pseudo: Pseudo, element: HTMLNode) -> Bool {
        switch pseudo {
        case .firstChild:
            return elementSiblings(of: element).first === element
        case .lastChild:
            return elementSiblings(of: element).last === element
        case .onlyChild:
            let siblings = elementSiblings(of: element)
            return siblings.count == 1
        case .firstOfType:
            return typedSiblings(of: element).first === element
        case .lastOfType:
            return typedSiblings(of: element).last === element
        case .empty:
            return element.children.allSatisfy { $0.kind != .element && $0.rawText.trimmed.isEmpty }
        case .root:
            return element.parent?.kind == .document
        case .nthChild(let a, let b):
            let siblings = elementSiblings(of: element)
            guard let position = siblings.firstIndex(where: { $0 === element }).map({ $0 + 1 }) else { return false }
            return nthMatches(position: position, a: a, b: b)
        case .not(let selector):
            return !CSSSelector.matches(selector, element: element)
        case .has(let selector):
            return !select(selector, in: element).isEmpty
        case .contains(let text):
            return element.rawText.contains(text)
        case .eq(let value):
            let siblings = elementSiblings(of: element)
            let position = siblings.firstIndex(where: { $0 === element })
            return position == value
        }
    }

    private static func nthMatches(position: Int, a: Int, b: Int) -> Bool {
        if a == 0 { return position == b }
        let difference = position - b
        if a > 0 { return difference >= 0 && difference % a == 0 }
        return difference <= 0 && difference % a == 0
    }

    private static func elementSiblings(of element: HTMLNode) -> [HTMLNode] {
        guard let parent = element.parent else { return [element] }
        return parent.children.filter { $0.isElement }
    }

    private static func typedSiblings(of element: HTMLNode) -> [HTMLNode] {
        elementSiblings(of: element).filter { $0.name == element.name }
    }

    private static func previousElementSibling(of element: HTMLNode) -> HTMLNode? {
        guard let parent = element.parent,
              let index = parent.children.firstIndex(where: { $0 === element }) else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if parent.children[cursor].isElement { return parent.children[cursor] }
            cursor -= 1
        }
        return nil
    }

    private static func allElements(in root: HTMLNode) -> [HTMLNode] {
        var result: [HTMLNode] = []
        var stack: [HTMLNode] = root.children.reversed()
        while let node = stack.popLast() {
            if node.isElement { result.append(node) }
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    private static func dedupeInDocumentOrder(_ nodes: [HTMLNode], root: HTMLNode) -> [HTMLNode] {
        guard nodes.count > 1 else { return nodes }
        var order: [ObjectIdentifier: Int] = [:]
        var counter = 0
        var stack: [HTMLNode] = [root]
        while let node = stack.popLast() {
            order[ObjectIdentifier(node)] = counter
            counter += 1
            stack.append(contentsOf: node.children.reversed())
        }
        var seen = Set<ObjectIdentifier>()
        var unique: [HTMLNode] = []
        for node in nodes where seen.insert(ObjectIdentifier(node)).inserted { unique.append(node) }
        return unique.sorted { (order[ObjectIdentifier($0)] ?? Int.max) < (order[ObjectIdentifier($1)] ?? Int.max) }
    }
}
