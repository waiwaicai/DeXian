import Foundation

/// XPath 1.0 取值结果
enum XPathValue {
    case nodeSet([HTMLNode])
    case string(String)
    case number(Double)
    case boolean(Bool)

    var isNodeSet: Bool { if case .nodeSet = self { return true }; return false }

    var nodes: [HTMLNode] {
        if case .nodeSet(let value) = self { return value }
        return []
    }

    var asString: String {
        switch self {
        case .nodeSet(let nodes):
            return nodes.first.map { XPathEngine.stringValue(of: $0) } ?? ""
        case .string(let value):
            return value
        case .number(let value):
            return XPathEngine.formatNumber(value)
        case .boolean(let value):
            return value ? "true" : "false"
        }
    }

    var asNumber: Double {
        switch self {
        case .number(let value): return value
        case .string(let value): return XPathEngine.parseNumber(value)
        case .boolean(let value): return value ? 1 : 0
        case .nodeSet(let nodes):
            guard let first = nodes.first else { return Double.nan }
            return XPathEngine.parseNumber(XPathEngine.stringValue(of: first))
        }
    }

    var asBool: Bool {
        switch self {
        case .boolean(let value): return value
        case .number(let value): return value != 0 && !value.isNaN
        case .string(let value): return !value.isEmpty
        case .nodeSet(let nodes): return !nodes.isEmpty
        }
    }
}

/// XPath 1.0 子集求值器。
///
/// 实现范围覆盖书源规则实际使用的全部语法：13 种轴、谓语（含 position/last）、
/// 并集、算术与逻辑运算符、常用核心函数。语义与浏览器一致。
enum XPathEngine {

    static func parse(document html: String) -> HTMLNode {
        HTMLParser.parse(html)
    }

    /// 文档节点的 string-value。
    static func stringValue(of node: HTMLNode?) -> String {
        guard let node else { return "" }
        switch node.kind {
        case .text, .attribute, .comment:
            return node.text
        case .document, .element:
            var buffer = ""
            collectStringValue(node, into: &buffer)
            return buffer
        }
    }

    private static func collectStringValue(_ node: HTMLNode, into buffer: inout String) {
        for child in node.children {
            switch child.kind {
            case .text: buffer += child.text
            case .comment: break
            default: collectStringValue(child, into: &buffer)
            }
        }
    }

    static func formatNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// XPath number() 转换：必须整体匹配数字字面量，否则 NaN。
    static func parseNumber(_ text: String) -> Double {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return Double.nan }
        if let number = Double(value) { return number }
        return Double.nan
    }

    static func evaluate(_ expression: String, document: HTMLNode) -> XPathValue {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpression.isEmpty else { return .nodeSet([]) }
        var tokenizer = XPathTokenizer(expression: trimmedExpression)
        let tokens = tokenizer.tokenize()
        var parser = XPathParser(tokens: tokens, document: document)
        return parser.evaluate()
    }

    /// 便捷入口：返回节点数组（文档序、去重）。
    static func nodes(_ expression: String, document: HTMLNode) -> [HTMLNode] {
        evaluate(expression, document: document).nodes
    }

    /// 便捷入口：返回字符串结果。
    static func string(_ expression: String, document: HTMLNode) -> String {
        evaluate(expression, document: document).asString
    }

    /// 便捷入口：在给定上下文节点下求相对表达式。
    static func nodes(_ expression: String, context: [HTMLNode], document: HTMLNode) -> [HTMLNode] {
        var tokenizer = XPathTokenizer(expression: expression)
        let tokens = tokenizer.tokenize()
        var parser = XPathParser(tokens: tokens, document: document, contextOverride: context)
        return parser.evaluate().nodes
    }
}

// MARK: - Token

enum XPathToken: Equatable {
    case slash
    case doubleSlash
    case dot
    case dotDot
    case at
    case axisSeparator
    case leftBracket
    case rightBracket
    case leftParen
    case rightParen
    case comma
    case pipe
    case star
    case name(String)
    case literal(String)
    case number(Double)
    case plus
    case minus
    case equal
    case notEqual
    case lessThan
    case lessOrEqual
    case greaterThan
    case greaterOrEqual
    case and
    case or
}

struct XPathTokenizer {
    let expression: String
    private var characters: [Character] = []
    private var index = 0

    init(expression: String) {
        self.expression = expression
        characters = Array(expression)
    }

    mutating func tokenize() -> [XPathToken] {
        var tokens: [XPathToken] = []
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }

            switch character {
            case "/":
                if peek(1) == "/" { tokens.append(.doubleSlash); index += 2 }
                else { tokens.append(.slash); index += 1 }
            case ".":
                if peek(1) == "." { tokens.append(.dotDot); index += 2 }
                else if let next = peek(1), next.isNumber { tokens.append(readNumber()); }
                else { tokens.append(.dot); index += 1 }
            case ":":
                if peek(1) == ":" { tokens.append(.axisSeparator); index += 2 }
                else { index += 1 }
            case "@": tokens.append(.at); index += 1
            case "[": tokens.append(.leftBracket); index += 1
            case "]": tokens.append(.rightBracket); index += 1
            case "(": tokens.append(.leftParen); index += 1
            case ")": tokens.append(.rightParen); index += 1
            case ",": tokens.append(.comma); index += 1
            case "|": tokens.append(.pipe); index += 1
            case "*": tokens.append(.star); index += 1
            case "+": tokens.append(.plus); index += 1
            case "-": tokens.append(.minus); index += 1
            case "=": tokens.append(.equal); index += 1
            case "!":
                if peek(1) == "=" { tokens.append(.notEqual); index += 2 } else { index += 1 }
            case "<":
                if peek(1) == "=" { tokens.append(.lessOrEqual); index += 2 }
                else { tokens.append(.lessThan); index += 1 }
            case ">":
                if peek(1) == "=" { tokens.append(.greaterOrEqual); index += 2 }
                else { tokens.append(.greaterThan); index += 1 }
            case "'", "\"":
                tokens.append(readLiteral(quote: character))
            default:
                if character.isNumber {
                    tokens.append(readNumber())
                } else if isNameStart(character) {
                    tokens.append(readNameOrOperator())
                } else {
                    index += 1
                }
            }
        }
        return tokens
    }

    private func peek(_ offset: Int) -> Character? {
        let target = index + offset
        return target < characters.count ? characters[target] : nil
    }

    private func isNameStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }

    private mutating func readNumber() -> XPathToken {
        var value = ""
        var hasDot = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                value.append(character); index += 1
            } else if character == ".", !hasDot {
                hasDot = true; value.append(character); index += 1
            } else {
                break
            }
        }
        return .number(Double(value) ?? 0)
    }

    private mutating func readLiteral(quote: Character) -> XPathToken {
        index += 1
        var value = ""
        while index < characters.count, characters[index] != quote {
            value.append(characters[index])
            index += 1
        }
        if index < characters.count { index += 1 }
        return .literal(value)
    }

    /// 名称与运算符（and/or/div/mod）共享词法，由解析器按位置区分。
    private mutating func readNameOrOperator() -> XPathToken {
        var value = ""
        while index < characters.count, isNameCharacter(characters[index]) {
            value.append(characters[index])
            index += 1
        }
        // 一律产出 .name：and / or / div / mod 也可能是元素名（例如 //div），
        // 交给语法分析按出现位置决定它到底是名字还是运算符。
        return .name(value)
    }
}

// MARK: - AST

indirect enum XPathExpression {
    case or(XPathExpression, XPathExpression)
    case and(XPathExpression, XPathExpression)
    case equality(XPathExpression, XPathExpression, Bool)      // isEqual
    case relational(XPathExpression, XPathExpression, String)   // < > <= >=
    case additive(XPathExpression, XPathExpression, Bool)       // isPlus
    case multiplicative(XPathExpression, XPathExpression, String)
    case negate(XPathExpression)
    case union(XPathExpression, XPathExpression)
    case path(XPathPathExpression)
    case filter([XPathExpression], XPathExpression)
    case function(String, [XPathExpression])
    case literal(String)
    case number(Double)
    case empty
}

indirect enum XPathPathExpression {
    case absolute(XPathStepList)
    case relative(XPathStepList)
    /// 以过滤表达式为起点的相对路径，例如 (//div)[1]/a
    case fromFilter([XPathExpression], XPathExpression, XPathStepList)
}

struct XPathStepList {
    var steps: [XPathStep]
}

struct XPathStep {
    var axis: XPathAxis
    var nodeTest: XPathNodeTest
    var predicates: [XPathExpression]
}

enum XPathAxis: String {
    case child
    case descendant
    case descendantOrSelf = "descendant-or-self"
    case selfAxis = "self"
    case parent
    case ancestor
    case ancestorOrSelf = "ancestor-or-self"
    case followingSibling = "following-sibling"
    case precedingSibling = "preceding-sibling"
    case following
    case preceding
    case attribute

    init?(name: String) {
        switch name.lowercased() {
        case "child": self = .child
        case "descendant": self = .descendant
        case "descendant-or-self": self = .descendantOrSelf
        case "self": self = .selfAxis
        case "parent": self = .parent
        case "ancestor": self = .ancestor
        case "ancestor-or-self": self = .ancestorOrSelf
        case "following-sibling": self = .followingSibling
        case "preceding-sibling": self = .precedingSibling
        case "following": self = .following
        case "preceding": self = .preceding
        case "attribute": self = .attribute
        default: return nil
        }
    }
}

enum XPathNodeTest {
    case name(String)
    case anyElement
    case anyNode
    case textNode
    case commentNode
    case attributeName(String)
    case attributeAny
}

// MARK: - Parser

struct XPathParser {
    let tokens: [XPathToken]
    let document: HTMLNode
    let contextOverride: [HTMLNode]?
    private var index = 0

    init(tokens: [XPathToken], document: HTMLNode, contextOverride: [HTMLNode]? = nil) {
        self.tokens = tokens
        self.document = document
        self.contextOverride = contextOverride
    }

    // MARK: 入口

    mutating func evaluate() -> XPathValue {
        let context = contextOverride ?? [document]
        let expression = parseExpression()
        return XPathEvaluator(document: document).evaluate(
            expression,
            context: XPathContext(nodes: context)
        )
    }

    // MARK: 表达式解析

    private var current: XPathToken? { index < tokens.count ? tokens[index] : nil }

    private mutating func advance() -> XPathToken? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func match(_ token: XPathToken) -> Bool {
        guard let current, current == token else { return false }
        index += 1
        return true
    }

    mutating func parseExpression() -> XPathExpression {
        parseOr()
    }

    private mutating func parseOr() -> XPathExpression {
        var left = parseAnd()
        while consumeOperatorName("or") {
            let right = parseAnd()
            left = .or(left, right)
        }
        return left
    }

    private mutating func parseAnd() -> XPathExpression {
        var left = parseEquality()
        while consumeOperatorName("and") {
            let right = parseEquality()
            left = .and(left, right)
        }
        return left
    }

    private mutating func parseEquality() -> XPathExpression {
        var left = parseRelational()
        while let token = current, token == .equal || token == .notEqual {
            index += 1
            let right = parseRelational()
            left = .equality(left, right, token == .equal)
        }
        return left
    }

    private mutating func parseRelational() -> XPathExpression {
        var left = parseAdditive()
        while let token = current {
            let op: String
            switch token {
            case .lessThan: op = "<"
            case .lessOrEqual: op = "<="
            case .greaterThan: op = ">"
            case .greaterOrEqual: op = ">="
            default: return left
            }
            index += 1
            let right = parseAdditive()
            left = .relational(left, right, op)
        }
        return left
    }

    private mutating func parseAdditive() -> XPathExpression {
        var left = parseMultiplicative()
        while let token = current, token == .plus || token == .minus {
            index += 1
            let right = parseMultiplicative()
            left = .additive(left, right, token == .plus)
        }
        return left
    }

    private mutating func parseMultiplicative() -> XPathExpression {
        var left = parseUnary()
        while let token = current {
            let op: String
            switch token {
            case .star: op = "*"
            case .name(let value) where value.lowercased() == "div": op = "div"
            case .name(let value) where value.lowercased() == "mod": op = "mod"
            default: return left
            }
            index += 1
            let right = parseUnary()
            left = .multiplicative(left, right, op)
        }
        return left
    }

    private mutating func parseUnary() -> XPathExpression {
        if match(.minus) {
            return .negate(parseUnary())
        }
        return parseUnion()
    }

    private mutating func parseUnion() -> XPathExpression {
        var left = parsePath()
        while match(.pipe) {
            let right = parsePath()
            left = .union(left, right)
        }
        return left
    }

    /// PathExpr := LocationPath | FilterExpr (('/'|'//') RelativeLocationPath)?
    private mutating func parsePath() -> XPathExpression {
        // 以 / 或 // 开头 => 绝对路径
        if current == .slash || current == .doubleSlash {
            let steps = parseStepList(allowLeadingSeparator: true)
            return .path(.absolute(steps))
        }

        // 以 step 开头（名称、*、@、.、..、axis::）=> 相对路径
        if startsWithStep() {
            let steps = parseStepList(allowLeadingSeparator: false)
            return .path(.relative(steps))
        }

        // 否则按 filter 表达式处理
        let primary = parsePrimary()
        var predicates: [XPathExpression] = []
        while current == .leftBracket {
            predicates.append(parsePredicate())
        }
        if current == .slash || current == .doubleSlash {
            let steps = parseStepList(allowLeadingSeparator: true)
            if predicates.isEmpty {
                // 例如 (//div)/a —— 用空谓语表示
                return .path(.fromFilter([], primary, steps))
            }
            return .path(.fromFilter(predicates, primary, steps))
        }
        if predicates.isEmpty {
            return primary
        }
        return .filter(predicates, primary)
    }

    private func startsWithStep() -> Bool {
        guard let token = current else { return false }
        switch token {
        case .dot, .dotDot, .at, .star:
            return true
        case .name:
            // name:: 或 name( 都不是 step 起点（函数调用属于 primary）
            if let next = peek(1), next == .axisSeparator { return true }
            if let next = peek(1), next == .leftParen { return false }
            return true
        default:
            return false
        }
    }

    private func peek(_ offset: Int) -> XPathToken? {
        let target = index + offset
        return target < tokens.count ? tokens[target] : nil
    }

    /// 运算符名称（and / or / div / mod）与元素名共用词法，
    /// 只有在表达式位置出现时才按运算符消费。
    private func isOperatorName(_ token: XPathToken?, _ keyword: String) -> Bool {
        guard let token, case .name(let value) = token else { return false }
        return value.lowercased() == keyword
    }

    private mutating func consumeOperatorName(_ keyword: String) -> Bool {
        guard isOperatorName(current, keyword) else { return false }
        index += 1
        return true
    }

    /// LocationPath 的步序列。
    /// 处理 "/" 与 "//"：其中 "//" 展开为 descendant-or-self::node()/ 。
    private mutating func parseStepList(allowLeadingSeparator: Bool) -> XPathStepList {
        var steps: [XPathStep] = []

        if allowLeadingSeparator {
            if match(.doubleSlash) {
                steps.append(XPathStep(axis: .descendantOrSelf, nodeTest: .anyNode, predicates: []))
            } else {
                _ = match(.slash)
            }
        }

        guard let firstStep = parseStep() else { return XPathStepList(steps: steps) }
        steps.append(firstStep)

        while true {
            if match(.doubleSlash) {
                steps.append(XPathStep(axis: .descendantOrSelf, nodeTest: .anyNode, predicates: []))
                guard let step = parseStep() else { break }
                steps.append(step)
                continue
            }
            if match(.slash) {
                guard let step = parseStep() else { break }
                steps.append(step)
                continue
            }
            break
        }

        return XPathStepList(steps: steps)
    }

    private mutating func parseStep() -> XPathStep? {
        guard let token = current else { return nil }

        switch token {
        case .dot:
            index += 1
            var predicates: [XPathExpression] = []
            while current == .leftBracket { predicates.append(parsePredicate()) }
            return XPathStep(axis: .selfAxis, nodeTest: .anyNode, predicates: predicates)
        case .dotDot:
            index += 1
            var predicates: [XPathExpression] = []
            while current == .leftBracket { predicates.append(parsePredicate()) }
            return XPathStep(axis: .parent, nodeTest: .anyNode, predicates: predicates)
        case .at:
            index += 1
            let test: XPathNodeTest
            if match(.star) {
                test = .attributeAny
            } else if case .name(let name) = current {
                index += 1
                test = .attributeName(name.lowercased())
            } else {
                test = .attributeAny
            }
            var predicates: [XPathExpression] = []
            while current == .leftBracket { predicates.append(parsePredicate()) }
            return XPathStep(axis: .attribute, nodeTest: test, predicates: predicates)
        case .star:
            index += 1
            var predicates: [XPathExpression] = []
            while current == .leftBracket { predicates.append(parsePredicate()) }
            return XPathStep(axis: .child, nodeTest: .anyElement, predicates: predicates)
        case .name(let name):
            if peek(1) == .axisSeparator {
                index += 2
                let axis = XPathAxis(name: name) ?? .child
                let test = parseNodeTest()
                var predicates: [XPathExpression] = []
                while current == .leftBracket { predicates.append(parsePredicate()) }
                return XPathStep(axis: axis, nodeTest: test, predicates: predicates)
            }
            index += 1
            let test = nodeTest(forName: name)
            var predicates: [XPathExpression] = []
            while current == .leftBracket { predicates.append(parsePredicate()) }
            return XPathStep(axis: .child, nodeTest: test, predicates: predicates)
        default:
            return nil
        }
    }

    private mutating func parseNodeTest() -> XPathNodeTest {
        if match(.star) { return .anyElement }
        guard case .name(let name)? = current else { return .anyNode }
        index += 1
        return nodeTest(forName: name)
    }

    private mutating func nodeTest(forName name: String) -> XPathNodeTest {
        let lowered = name.lowercased()
        if current == .leftParen {
            switch lowered {
            case "node":
                consumeEmptyParens()
                return .anyNode
            case "text":
                consumeEmptyParens()
                return .textNode
            case "comment":
                consumeEmptyParens()
                return .commentNode
            default:
                // processing-instruction 等，按任意节点处理
                consumeEmptyParens()
                return .anyNode
            }
        }
        return .name(lowered)
    }

    private mutating func consumeEmptyParens() {
        _ = match(.leftParen)
        while current != nil, current != .rightParen { index += 1 }
        _ = match(.rightParen)
    }

    private mutating func parsePredicate() -> XPathExpression {
        _ = match(.leftBracket)
        let expression = parseExpression()
        _ = match(.rightBracket)
        return expression
    }

    private mutating func parsePrimary() -> XPathExpression {
        guard let token = current else { return .empty }
        switch token {
        case .leftParen:
            index += 1
            let expression = parseExpression()
            _ = match(.rightParen)
            return expression
        case .literal(let value):
            index += 1
            return .literal(value)
        case .number(let value):
            index += 1
            return .number(value)
        case .name(let name):
            if peek(1) == .leftParen {
                index += 2
                var arguments: [XPathExpression] = []
                if current != .rightParen {
                    arguments.append(parseExpression())
                    while match(.comma) {
                        arguments.append(parseExpression())
                    }
                }
                _ = match(.rightParen)
                return .function(name.lowercased(), arguments)
            }
            index += 1
            return .empty
        default:
            index += 1
            return .empty
        }
    }
}

// MARK: - 求值

struct XPathContext {
    var nodes: [HTMLNode]
    /// 谓词求值时的上下文位置（从 1 开始）
    var position: Int = 1
    /// 谓词求值时的上下文规模
    var size: Int = 1

    static var empty: XPathContext { XPathContext(nodes: []) }
}

struct XPathEvaluator {
    let document: HTMLNode

    func evaluate(_ expression: XPathExpression, context: XPathContext) -> XPathValue {
        switch expression {
        case .empty:
            return .nodeSet([])

        case .literal(let value):
            return .string(value)

        case .number(let value):
            return .number(value)

        case .negate(let operand):
            return .number(-evaluate(operand, context: context).asNumber)

        case .or(let left, let right):
            return .boolean(evaluate(left, context: context).asBool || evaluate(right, context: context).asBool)

        case .and(let left, let right):
            return .boolean(evaluate(left, context: context).asBool && evaluate(right, context: context).asBool)

        case .equality(let left, let right, let isEqual):
            let result = compareEquality(evaluate(left, context: context), evaluate(right, context: context))
            return .boolean(isEqual ? result : !result)

        case .relational(let left, let right, let op):
            return .boolean(compareRelational(evaluate(left, context: context), evaluate(right, context: context), op))

        case .additive(let left, let right, let isPlus):
            let lhs = evaluate(left, context: context).asNumber
            let rhs = evaluate(right, context: context).asNumber
            return .number(isPlus ? lhs + rhs : lhs - rhs)

        case .multiplicative(let left, let right, let op):
            let lhs = evaluate(left, context: context).asNumber
            let rhs = evaluate(right, context: context).asNumber
            switch op {
            case "*": return .number(lhs * rhs)
            case "div": return .number(lhs / rhs)
            default: return .number(lhs.truncatingRemainder(dividingBy: rhs))
            }

        case .union(let left, let right):
            let lhs = evaluate(left, context: context).nodes
            let rhs = evaluate(right, context: context).nodes
            return .nodeSet(sortAndDedupe(lhs + rhs))

        case .filter(let predicates, let primary):
            let value = evaluate(primary, context: context)
            guard value.isNodeSet else { return value }
            return .nodeSet(applyPredicates(predicates, to: value.nodes, context: context))

        case .function(let name, let arguments):
            return evaluateFunction(name: name, arguments: arguments, context: context)

        case .path(let path):
            return evaluatePath(path, context: context)
        }
    }

    // MARK: 路径

    private func evaluatePath(_ path: XPathPathExpression, context: XPathContext) -> XPathValue {
        switch path {
        case .absolute(let stepList):
            var current = [document]
            return .nodeSet(applySteps(stepList.steps, start: current))

        case .relative(let stepList):
            let start = context.nodes.isEmpty ? [document] : context.nodes
            return .nodeSet(applySteps(stepList.steps, start: start))

        case .fromFilter(let predicates, let primary, let stepList):
            let base = evaluate(primary, context: context)
            var start = base.nodes
            if !predicates.isEmpty {
                start = applyPredicates(predicates, to: start, context: context)
            }
            return .nodeSet(applySteps(stepList.steps, start: start))
        }
    }

    private func applySteps(_ steps: [XPathStep], start: [HTMLNode]) -> [HTMLNode] {
        var current = start
        for step in steps {
            // 轴节点集按“每个上下文节点分别求值 + 谓语”计算，与浏览器一致
            var result: [HTMLNode] = []
            for node in current {
                var axisNodes = nodes(for: step.axis, nodeTest: step.nodeTest, of: node)
                if !step.predicates.isEmpty {
                    axisNodes = applyPredicates(
                        step.predicates,
                        to: axisNodes,
                        context: XPathContext(nodes: [node])
                    )
                }
                result.append(contentsOf: axisNodes)
            }
            current = sortAndDedupe(result)
            if current.isEmpty { break }
        }
        return current
    }

    private func nodes(for axis: XPathAxis, nodeTest: XPathNodeTest, of node: HTMLNode) -> [HTMLNode] {
        switch axis {
        case .child:
            return filter(node.children, with: nodeTest, of: node)
        case .descendant:
            return filter(descendants(of: node, includeSelf: false), with: nodeTest, of: node)
        case .descendantOrSelf:
            return filter(descendants(of: node, includeSelf: true), with: nodeTest, of: node)
        case .selfAxis:
            return filter([node], with: nodeTest, of: node)
        case .parent:
            guard let parent = node.parent else { return [] }
            return filter([parent], with: nodeTest, of: node)
        case .ancestor:
            return filter(ancestors(of: node, includeSelf: false), with: nodeTest, of: node)
        case .ancestorOrSelf:
            return filter(ancestors(of: node, includeSelf: true), with: nodeTest, of: node)
        case .followingSibling:
            guard let parent = node.parent,
                  let position = parent.children.firstIndex(where: { $0 === node }) else { return [] }
            let siblings = Array(parent.children[(position + 1)...])
            return filter(siblings, with: nodeTest, of: node)
        case .precedingSibling:
            guard let parent = node.parent,
                  let position = parent.children.firstIndex(where: { $0 === node }) else { return [] }
            let siblings = Array(parent.children[..<position])
            return filter(siblings, with: nodeTest, of: node)
        case .following:
            return filter(followingNodes(of: node), with: nodeTest, of: node)
        case .preceding:
            return filter(precedingNodes(of: node), with: nodeTest, of: node)
        case .attribute:
            return attributeNodes(of: node, test: nodeTest)
        }
    }

    private func filter(_ nodes: [HTMLNode], with test: XPathNodeTest, of owner: HTMLNode) -> [HTMLNode] {
        switch test {
        case .name(let name):
            return nodes.filter { $0.kind == .element && $0.name == name }
        case .anyElement:
            return nodes.filter { $0.kind == .element }
        case .anyNode:
            return nodes
        case .textNode:
            return nodes.filter { $0.kind == .text }
        case .commentNode:
            return nodes.filter { $0.kind == .comment }
        case .attributeName, .attributeAny:
            return nodes
        }
    }

    private func attributeNodes(of node: HTMLNode, test: XPathNodeTest) -> [HTMLNode] {
        guard node.kind == .element else { return [] }
        switch test {
        case .attributeAny:
            return node.attributes.keys.sorted().compactMap { node.attributeNode(named: $0) }
        case .attributeName(let name):
            return node.attributeNode(named: name).map { [$0] } ?? []
        default:
            return []
        }
    }

    private func descendants(of node: HTMLNode, includeSelf: Bool) -> [HTMLNode] {
        var result: [HTMLNode] = includeSelf ? [node] : []
        var queue = node.children
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            result.append(current)
            if current.kind == .element || current.kind == .document {
                queue.append(contentsOf: current.children)
            }
            cursor += 1
        }
        return result
    }

    private func ancestors(of node: HTMLNode, includeSelf: Bool) -> [HTMLNode] {
        var result: [HTMLNode] = includeSelf ? [node] : []
        var cursor = node.parent
        while let current = cursor {
            result.append(current)
            cursor = current.parent
        }
        return result
    }

    private func followingNodes(of node: HTMLNode) -> [HTMLNode] {
        // 文档序中位于其后、且不是其后代
        let all = documentOrder()
        guard let position = all.firstIndex(where: { $0 === node }) else { return [] }
        let descendantSet = Set(descendants(of: node, includeSelf: false).map { ObjectIdentifier($0) })
        return all[(position + 1)...].filter { !descendantSet.contains(ObjectIdentifier($0)) }
    }

    private func precedingNodes(of node: HTMLNode) -> [HTMLNode] {
        let all = documentOrder()
        guard let position = all.firstIndex(where: { $0 === node }) else { return [] }
        let ancestorSet = Set(ancestors(of: node, includeSelf: false).map { ObjectIdentifier($0) })
        return all[..<position].filter { !ancestorSet.contains(ObjectIdentifier($0)) }
    }

    private func documentOrder() -> [HTMLNode] {
        var result: [HTMLNode] = []
        var stack: [HTMLNode] = [document]
        while let node = stack.popLast() {
            result.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    // MARK: 谓语

    private func applyPredicates(_ predicates: [XPathExpression], to nodes: [HTMLNode], context: XPathContext) -> [HTMLNode] {
        var result = nodes
        for predicate in predicates {
            var filtered: [HTMLNode] = []
            let size = result.count
            for (offset, node) in result.enumerated() {
                let nodeContext = XPathContext(nodes: [node], position: offset + 1, size: size)
                let value = evaluate(predicate, context: nodeContext)
                if predicateMatches(value, position: offset + 1, size: size) {
                    filtered.append(node)
                }
            }
            result = filtered
        }
        return result
    }

    /// 谓词结果为数字时表示位置；否则取布尔值。
    private func predicateMatches(_ value: XPathValue, position: Int, size: Int) -> Bool {
        if case .number(let number) = value {
            return Double(position) == number
        }
        return value.asBool
    }

    // MARK: 比较

    private func compareEquality(_ left: XPathValue, _ right: XPathValue) -> Bool {
        switch (left, right) {
        case (.nodeSet(let lhs), .nodeSet(let rhs)):
            let rhsStrings = rhs.map { XPathEngine.stringValue(of: $0) }
            for node in lhs where rhsStrings.contains(XPathEngine.stringValue(of: node)) { return true }
            return false

        case (.nodeSet(let nodes), let other):
            return compareNodeSet(nodes, with: other)
        case (let other, .nodeSet(let nodes)):
            return compareNodeSet(nodes, with: other)

        case (.boolean(let lhs), let other):
            return lhs == other.asBool
        case (let other, .boolean(let rhs)):
            return rhs == other.asBool

        case (.number(let lhs), let other):
            return lhs == other.asNumber
        case (let other, .number(let rhs)):
            return rhs == other.asNumber

        default:
            return left.asString == right.asString
        }
    }

    private func compareNodeSet(_ nodes: [HTMLNode], with other: XPathValue) -> Bool {
        switch other {
        case .boolean(let value):
            return !nodes.isEmpty == value
        case .number(let value):
            return nodes.contains { XPathEngine.parseNumber(XPathEngine.stringValue(of: $0)) == value }
        case .string(let value):
            return nodes.contains { XPathEngine.stringValue(of: $0) == value }
        case .nodeSet:
            return false
        }
    }

    private func compareRelational(_ left: XPathValue, _ right: XPathValue, _ op: String) -> Bool {
        let lhsNumbers: [Double]
        let rhsNumbers: [Double]

        if case .nodeSet(let nodes) = left {
            lhsNumbers = nodes.map { XPathEngine.parseNumber(XPathEngine.stringValue(of: $0)) }
        } else {
            lhsNumbers = [left.asNumber]
        }
        if case .nodeSet(let nodes) = right {
            rhsNumbers = nodes.map { XPathEngine.parseNumber(XPathEngine.stringValue(of: $0)) }
        } else {
            rhsNumbers = [right.asNumber]
        }

        for lhs in lhsNumbers {
            for rhs in rhsNumbers {
                switch op {
                case "<": if lhs < rhs { return true }
                case "<=": if lhs <= rhs { return true }
                case ">": if lhs > rhs { return true }
                case ">=": if lhs >= rhs { return true }
                default: break
                }
            }
        }
        return false
    }

    // MARK: 函数

    private func evaluateFunction(name: String, arguments: [XPathExpression], context: XPathContext) -> XPathValue {
        func argument(_ offset: Int) -> XPathValue {
            guard offset < arguments.count else { return .nodeSet([]) }
            return evaluate(arguments[offset], context: context)
        }

        let contextNode = context.nodes.first

        switch name {
        case "text":
            guard let node = contextNode else { return .nodeSet([]) }
            return .nodeSet(node.children.filter { $0.kind == .text })

        case "node":
            return .nodeSet(context.nodes)

        case "string":
            if arguments.isEmpty {
                return .string(contextNode.map { XPathEngine.stringValue(of: $0) } ?? "")
            }
            return .string(argument(0).asString)

        case "concat":
            return .string(arguments.map { evaluate($0, context: context).asString }.joined())

        case "starts-with":
            return .boolean(argument(0).asString.hasPrefix(argument(1).asString))

        case "contains":
            let haystack = argument(0).asString
            let needle = argument(1).asString
            if needle.isEmpty { return .boolean(true) }
            return .boolean(haystack.contains(needle))

        case "substring-before":
            let source = argument(0).asString
            let separator = argument(1).asString
            guard !separator.isEmpty, let range = source.range(of: separator) else { return .string("") }
            return .string(String(source[..<range.lowerBound]))

        case "substring-after":
            let source = argument(0).asString
            let separator = argument(1).asString
            guard !separator.isEmpty, let range = source.range(of: separator) else { return .string("") }
            return .string(String(source[range.upperBound...]))

        case "substring":
            return .string(substring(of: argument(0).asString,
                                     start: argument(1).asNumber,
                                     length: arguments.count >= 3 ? argument(2).asNumber : nil))

        case "string-length":
            let value = arguments.isEmpty
                ? (contextNode.map { XPathEngine.stringValue(of: $0) } ?? "")
                : argument(0).asString
            return .number(Double(value.count))

        case "normalize-space":
            let value = arguments.isEmpty
                ? (contextNode.map { XPathEngine.stringValue(of: $0) } ?? "")
                : argument(0).asString
            return .string(HTMLNode.normalizeWhitespace(value))

        case "translate":
            return .string(translate(argument(0).asString,
                                     from: argument(1).asString,
                                     to: argument(2).asString))

        case "boolean":
            return .boolean(argument(0).asBool)

        case "not":
            return .boolean(!argument(0).asBool)

        case "true":
            return .boolean(true)

        case "false":
            return .boolean(false)

        case "number":
            if arguments.isEmpty {
                return .number(contextNode.map { XPathEngine.parseNumber(XPathEngine.stringValue(of: $0)) } ?? Double.nan)
            }
            return .number(argument(0).asNumber)

        case "sum":
            let nodes = argument(0).nodes
            var total = 0.0
            for node in nodes {
                let value = XPathEngine.parseNumber(XPathEngine.stringValue(of: node))
                if value.isNaN { return .number(Double.nan) }
                total += value
            }
            return .number(total)

        case "floor":
            return .number(argument(0).asNumber.rounded(.down))

        case "ceiling":
            return .number(argument(0).asNumber.rounded(.up))

        case "round":
            let value = argument(0).asNumber
            if value.isNaN { return .number(Double.nan) }
            return .number((value + 0.5).rounded(.down))

        case "count":
            return .number(Double(argument(0).nodes.count))

        case "position":
            return .number(Double(context.position))

        case "last":
            return .number(Double(context.size))

        case "name", "local-name":
            guard let node = argument(0).nodes.first ?? contextNode else { return .string("") }
            return .string(node.kind == .attribute ? String(node.name.dropFirst()) : node.name)

        case "namespace-uri":
            return .string("")

        case "id":
            let identifiers = argument(0).asString
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .map(String.init)
            var matches: [HTMLNode] = []
            for identifier in identifiers {
                let found = descendants(of: document, includeSelf: true).filter {
                    $0.kind == .element && $0.attribute("id") == identifier
                }
                matches.append(contentsOf: found)
            }
            return .nodeSet(sortAndDedupe(matches))

        case "lang":
            return .boolean(false)

        default:
            return .nodeSet([])
        }
    }

    private func substring(of source: String, start: Double, length: Double?) -> String {
        if start.isNaN { return "" }
        let characters = Array(source)
        let startIndex = start.rounded()
        let endIndex: Double
        if let length {
            if length.isNaN { return "" }
            endIndex = startIndex + length.rounded()
        } else {
            endIndex = Double.infinity
        }
        var result = ""
        for (offset, character) in characters.enumerated() {
            let position = Double(offset + 1)
            if position >= startIndex, position < endIndex {
                result.append(character)
            }
        }
        return result
    }

    private func translate(_ source: String, from: String, to: String) -> String {
        let fromCharacters = Array(from)
        let toCharacters = Array(to)
        var mapping: [Character: Character?] = [:]
        for (offset, character) in fromCharacters.enumerated() {
            if mapping[character] != nil { continue }
            mapping[character] = offset < toCharacters.count ? toCharacters[offset] : Character?.none
        }
        var result = ""
        for character in source {
            if let mapped = mapping[character] {
                if let replacement = mapped { result.append(replacement) }
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: 排序

    private func sortAndDedupe(_ nodes: [HTMLNode]) -> [HTMLNode] {
        guard nodes.count > 1 else { return nodes }
        var order: [ObjectIdentifier: Int] = [:]
        var counter = 0
        var stack: [HTMLNode] = [document]
        while let node = stack.popLast() {
            order[ObjectIdentifier(node)] = counter
            counter += 1
            stack.append(contentsOf: node.children.reversed())
        }
        var seen = Set<ObjectIdentifier>()
        var unique: [HTMLNode] = []
        for node in nodes where seen.insert(ObjectIdentifier(node)).inserted {
            unique.append(node)
        }
        func rank(_ node: HTMLNode) -> Int {
            if let value = order[ObjectIdentifier(node)] { return value }
            // 属性节点跟随其宿主元素排序
            if let owner = node.parent, let value = order[ObjectIdentifier(owner)] { return value }
            return Int.max
        }
        return unique.sorted { rank($0) < rank($1) }
    }
}
