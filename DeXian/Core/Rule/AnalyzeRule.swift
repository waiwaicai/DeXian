import Foundation

/// 规则求值中间值。
enum RuleValue {
    /// HTML 节点集合（来自 CSS / XPath）
    case nodes([HTMLNode])
    /// 字符串集合（来自 JSON / 正则 / 字面量）
    case strings([String])
    /// 原始对象（JS 返回值）
    case raw(Any)

    var strings: [String] {
        switch self {
        case .nodes(let nodes):
            return nodes.map { XPathEngine.stringValue(of: $0) }
        case .strings(let values):
            return values
        case .raw(let any):
            if let list = any as? [Any] { return list.map { RuleUtil.asString($0) ?? "" } }
            return RuleUtil.asString(any).map { [$0] } ?? []
        }
    }

    var nodes: [HTMLNode] {
        if case .nodes(let values) = self { return values }
        return []
    }

    var isEmpty: Bool {
        switch self {
        case .nodes(let nodes): return nodes.isEmpty
        case .strings(let values): return values.isEmpty
        case .raw(let any): return RuleUtil.asString(any)?.isEmpty ?? true
        }
    }

    /// 供 JS 的 result 变量使用：单项给字符串，多项给数组。
    var jsValue: Any? {
        switch self {
        case .nodes(let nodes):
            let values = nodes.map { XPathEngine.stringValue(of: $0) }
            return values.count == 1 ? values[0] : values
        case .strings(let values):
            return values.count == 1 ? values[0] : values
        case .raw(let any):
            return any
        }
    }
}

/// 规则求值上下文。
struct RuleContext {
    /// 当前内容：HTML 字符串 / JSON 对象 / 节点 / 字典
    var content: Any?
    /// HTML 文档（惰性）
    var document: HTMLNode?
    var baseUrl: String?
    /// JS 求值：参数为 (脚本, 前一步结果)，前一步结果对应 JS 里的 result 变量
    var evaluateJS: ((String, Any?) -> Any?)?
    var getVariable: ((String) -> String?)?
    var putVariable: ((String, String?) -> Void)?

    init(content: Any?, baseUrl: String? = nil) {
        self.content = content
        self.baseUrl = baseUrl
        if let node = content as? HTMLNode {
            self.document = node
        } else if let text = content as? String {
            self.document = HTMLParser.parse(text)
        } else {
            self.document = nil
        }
    }

    /// 换掉内容、保留全部回调（JS / 变量读写），用于 JS 结果续接静态规则。
    func replacingContent(_ newContent: Any?) -> RuleContext {
        var context = RuleContext(content: newContent, baseUrl: baseUrl)
        context.evaluateJS = evaluateJS
        context.getVariable = getVariable
        context.putVariable = putVariable
        return context
    }
}

/// 规则求值器。
///
/// 支持 Legado 的完整规则语法：
/// - 规则标志：@css: @xpath: @json: @regex: @@ 双斜杠 美元符号 冒号正则
/// - 规则链：美元路径@js:... 、xpath@href 、css选择器@text
/// - 组合：双竖线取首个非空、双与号连接
/// - 后处理：两个井号包裹的正则替换
/// - 插值：花括号 page / key / book.name
final class AnalyzeRule {

    private let context: RuleContext
    var page: Int = 1
    var key: String = ""
    /// 供 {{book.xxx}} / {{chapter.xxx}} 使用
    var bookVariables: [String: String] = [:]
    var chapterVariables: [String: String] = [:]

    init(context: RuleContext) {
        self.context = context
    }

    convenience init(content: Any?, baseUrl: String? = nil) {
        self.init(context: RuleContext(content: content, baseUrl: baseUrl))
    }

    // MARK: 对外接口

    func string(_ rule: String?) -> String {
        stringList(rule).first ?? ""
    }

    func stringList(_ rule: String?) -> [String] {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        for branch in RuleSyntax.splitTopLevel(rule, separator: "||") {
            let value = evaluateRule(branch)
            let strings = value.strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !strings.isEmpty { return strings }
        }
        return []
    }

    /// 取规则的「HTML 形态」结果。
    ///
    /// 漫画源的正文规则经常直接选中 img 所在容器（例：class.comic-contain），
    /// 这时如果走 string()，节点会被拍平成纯文本，<img> 全部丢失，
    /// extractImages 就再也找不到图片。节点结果保留 outerHTML。
    func htmlString(_ rule: String?) -> String {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        for branch in RuleSyntax.splitTopLevel(rule, separator: "||") {
            let value = evaluateRule(branch)
            switch value {
            case .nodes(let nodes):
                let html = nodes.map { $0.outerHTML }.joined(separator: "\n")
                if !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return html }
            case .strings(let values):
                let merged = values.joined(separator: "\n")
                if !merged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return merged }
            case .raw(let any):
                if let node = any as? HTMLNode { return node.outerHTML }
                if let text = RuleUtil.asString(any), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
        }
        return ""
    }

    /// 列表规则（书籍列表 / 目录列表）：返回条目（HTMLNode 或 JSON 对象）。
    func listItems(_ rule: String?) -> [Any] {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        for branch in RuleSyntax.splitTopLevel(rule, separator: "||") {
            let items = evaluateListRule(branch)
            if !items.isEmpty { return items }
        }
        return []
    }

    // MARK: 规则链

    /// 求值单条规则（含 @ 链与内嵌 <js> 段）。
    private func evaluateRule(_ rule: String) -> RuleValue {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .strings([]) }

        let (core, replacements) = RuleSyntax.splitReplaceRule(text)
        var value = evaluateChained(core)
        if !replacements.isEmpty {
            value = .strings(applyReplacements(value.strings, replacements: replacements))
        }
        return value
    }

    /// 求值规则；内嵌 <js>…</js> 段先跑，其结果作为后续规则的输入。
    private func evaluateChained(_ text: String) -> RuleValue {
        let pieces = RuleSyntax.splitJSSegments(text)
        guard pieces.count > 1 else {
            let segments = RuleSyntax.splitChain(text)
            guard !segments.isEmpty else { return .strings([]) }
            var value = evaluateBase(segments[0])
            for segment in segments.dropFirst() { value = applyTransform(segment, to: value) }
            return value
        }

        var value = RuleValue.strings([])
        for (isJS, piece) in pieces {
            if isJS {
                let result = runJS(piece, previous: value.isEmpty ? nil : value.jsValue)
                value = .raw(result ?? "")
            } else {
                value = evaluateSegment(piece, previous: value)
            }
        }
        return value
    }

    /// 求值一段静态规则。
    ///
    /// 前面没有 JS 结果时按普通规则（可能含 @ 链）求值；
    /// 已有 JS 结果时，对齐 Legado：以该结果为内容重新起一条规则，
    /// 例 `<js>GetList(result)</js>$.data.list[*]`。
    private func evaluateSegment(_ piece: String, previous: RuleValue) -> RuleValue {
        let segments = RuleSyntax.splitChain(piece)
        guard !segments.isEmpty else { return previous }
        if previous.isEmpty {
            var value = evaluateBase(segments[0])
            for segment in segments.dropFirst() { value = applyTransform(segment, to: value) }
            return value
        }
        // 链式记号（@href / @text / @js: 等）直接作用在上一段结果上
        if segments.count == 1, isTransformMarker(segments[0]) {
            return applyTransform(segments[0], to: previous)
        }
        let content: Any?
        switch previous {
        case .nodes(let nodes): content = nodes.first
        case .raw(let any): content = any
        case .strings(let values): content = values.count == 1 ? values[0] : values
        }
        let nested = AnalyzeRule(context: context.replacingContent(content))
        nested.page = page
        nested.key = key
        nested.bookVariables = bookVariables
        nested.chapterVariables = chapterVariables
        var value = nested.evaluateBase(segments[0])
        for segment in segments.dropFirst() { value = nested.applyTransform(segment, to: value) }
        return value
    }

    /// 是否是作用在上一段结果上的链式记号。
    private func isTransformMarker(_ segment: String) -> Bool {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        for prefix in ["js:", "@js:", "<js>", "json:", "@json:", "css:", "@css:", "xpath:", "@xpath:", "regex:", "@regex:", "attr:"] {
            if lowered.hasPrefix(prefix) { return true }
        }
        switch lowered {
        case "text", "owntext", "textnodes", "html", "outerhtml", "all": return true
        default: break
        }
        // 形如 href / src / data-src 的纯属性名
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// 列表求值：JSON 数组自动展开。
    private func evaluateListRule(_ rule: String) -> [Any] {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var reversed = false
        if text.hasPrefix("-") {
            reversed = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let (core, _) = RuleSyntax.splitReplaceRule(text)
        let value = evaluateChained(core)
        var items: [Any] = []

        switch value {
        case .nodes(let nodes):
            items = nodes
        case .strings(let values):
            items = values
        case .raw(let any):
            if let array = any as? [Any] {
                items = array
            } else if let array = RuleUtil.asString(any).flatMap({ $0.jsonObject as? [Any] }) {
                items = array
            } else {
                items = [any]
            }
        }

        if items.count == 1, let array = items[0] as? [Any] {
            items = array
        }
        if reversed { items.reverse() }
        return items
    }

    /// 基础规则（链的第一段）
    private func evaluateBase(_ rule: String) -> RuleValue {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        var reversed = false
        if text.hasPrefix("-") {
            reversed = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let interpolated = interpolate(text)
        guard !interpolated.isBlank else { return .strings([]) }

        let (kind, body) = RuleSyntax.detectKind(interpolated)

        switch kind {
        case .javascript:
            let value = runJS(body)
            return .raw(value ?? "")

        case .json:
            guard let json = jsonContent() else { return .strings([]) }
            var path = body
            var collectAll = false
            if path.hasSuffix("#") {
                collectAll = true
                path = String(path.dropLast())
            }
            let results = JSONPath.query(path, json: json)
            if collectAll {
                var flattened: [String] = []
                for result in results {
                    if let array = result as? [Any] {
                        flattened.append(contentsOf: array.map { RuleUtil.asString($0) ?? "" })
                    } else {
                        flattened.append(RuleUtil.asString(result) ?? "")
                    }
                }
                return .strings(flattened)
            }
            if results.count == 1, let array = results[0] as? [Any] {
                return .strings(array.map { RuleUtil.asString($0) ?? "" })
            }
            return .raw(results.count == 1 ? results[0] : results)

        case .regex:
            return .strings(applyRegexRule(interpolated))

        case .xpath, .css:
            guard let document = context.document else {
                if let text = context.content as? String { return .strings([text]) }
                return .strings([])
            }
            var nodes: [HTMLNode]
            if kind == .xpath {
                nodes = XPathEngine.nodes(body, document: document)
            } else if LegacySelector.isLegacy(body) {
                // Legado 默认规则：class. / tag. / id. / text. / children
                nodes = LegacySelector.select(body, in: document)
            } else {
                nodes = CSSSelector.select(body, in: document)
            }
            if reversed { nodes.reverse() }
            return .nodes(nodes)

        case .literal:
            return .strings([interpolated])
        }
    }

    /// 链式转换（@ 之后的段）
    private func applyTransform(_ segment: String, to value: RuleValue) -> RuleValue {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return value }
        let lowered = text.lowercased()

        if lowered.hasPrefix("js:") {
            let script = String(text.dropFirst(3))
            let result = runJS(script, previous: value.jsValue)
            return .raw(result ?? "")
        }
        if lowered.hasPrefix("@js:") {
            let script = String(text.dropFirst(4))
            let result = runJS(script, previous: value.jsValue)
            return .raw(result ?? "")
        }
        if lowered.hasPrefix("<js>") {
            let (kind, body) = RuleSyntax.detectKind(text)
            guard kind == .javascript else { return value }
            let result = runJS(body, previous: value.jsValue)
            return .raw(result ?? "")
        }
        if lowered.hasPrefix("json:") {
            let path = String(text.dropFirst(5))
            guard let json = jsonFromValue(value) else { return .strings([]) }
            let results = JSONPath.query(path, json: json)
            if results.count == 1, let array = results[0] as? [Any] {
                return .strings(array.map { RuleUtil.asString($0) ?? "" })
            }
            return .raw(results.count == 1 ? results[0] : results)
        }
        if lowered.hasPrefix("css:") {
            guard let document = documentFromValue(value) else { return .strings([]) }
            return .nodes(CSSSelector.select(String(text.dropFirst(4)), in: document))
        }
        if LegacySelector.isLegacy(text) {
            // 节点集合上继续套选择器：对每个节点分别求值再拼接结果
            // （例：class.item@tag.a@text 需要得到全部 3 个书名，而不是只取第一个）
            if case .nodes(let nodes) = value, nodes.count > 1 {
                var combined: [HTMLNode] = []
                var seen = Set<ObjectIdentifier>()
                for node in nodes {
                    for found in LegacySelector.select(text, in: node) {
                        if seen.insert(ObjectIdentifier(found)).inserted { combined.append(found) }
                    }
                }
                return .nodes(combined)
            }
            guard let document = documentFromValue(value) else { return .strings([]) }
            return .nodes(LegacySelector.select(text, in: document))
        }
        if lowered.hasPrefix("xpath:") {
            guard let document = documentFromValue(value) else { return .strings([]) }
            return .nodes(XPathEngine.nodes(String(text.dropFirst(6)), document: document))
        }
        if lowered.hasPrefix("regex:") {
            let pattern = String(text.dropFirst(6))
            let sources = value.strings
            var results: [String] = []
            for source in sources { results.append(contentsOf: RuleUtil.regexMatch(source, pattern: pattern)) }
            return .strings(results)
        }

        return extractField(text, from: value)
    }

    private func extractField(_ field: String, from value: RuleValue) -> RuleValue {
        let nodes = value.nodes
        let lowered = field.lowercased()

        guard !nodes.isEmpty else {
            return .strings(value.strings)
        }

        switch lowered {
        case "text":
            return .strings(nodes.map { XPathEngine.stringValue(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) })
        case "owntext":
            return .strings(nodes.map { $0.ownText.trimmingCharacters(in: .whitespacesAndNewlines) })
        case "textnodes":
            var values: [String] = []
            for node in nodes {
                values.append(contentsOf: node.children
                    .filter { $0.kind == .text }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
            }
            return .strings(values)
        case "html":
            return .strings(nodes.map { $0.innerHTML })
        case "outerhtml", "all":
            return .strings(nodes.map { $0.outerHTML })
        default:
            break
        }

        var attribute = field
        if lowered.hasPrefix("attr:") { attribute = String(field.dropFirst(5)) }

        let values = nodes.map { $0.attribute(attribute) ?? "" }
        if values.contains(where: { !$0.isEmpty }) {
            return .strings(values)
        }
        return .strings(nodes.map { XPathEngine.stringValue(of: $0) })
    }

    // MARK: JS

    private func runJS(_ script: String, previous: Any? = nil) -> Any? {
        guard let evaluate = context.evaluateJS else { return nil }
        // 前一步结果注入 JS 的 result 变量，支持 result 参与计算
        if let previous {
            context.putVariable?("result", RuleUtil.asString(previous))
        }
        return evaluate(script, previous)
    }

    // MARK: 正则

    private func applyRegexRule(_ rule: String) -> [String] {
        let source: String
        if let text = context.content as? String {
            source = text
        } else if let document = context.document {
            source = document.rawText
        } else if let text = RuleUtil.asString(context.content) {
            source = text
        } else {
            return []
        }

        var body = rule
        if body.hasPrefix(":regex:") { body = String(body.dropFirst(7)) }
        else if body.hasPrefix(":") { body = String(body.dropFirst(1)) }

        let (pattern, replacements) = RuleSyntax.splitReplaceRule(body)
        if !replacements.isEmpty {
            return applyReplacements([source], replacements: replacements)
        }
        return RuleUtil.regexMatch(source, pattern: pattern)
    }

    // MARK: 后处理替换

    private func applyReplacements(_ values: [String], replacements: [(String, String)]) -> [String] {
        return values.map { value in
            var result = value
            for (pattern, replacement) in replacements {
                result = RuleUtil.regexReplace(result, pattern: pattern, replacement: replacement)
            }
            return result
        }
    }

    // MARK: 内容辅助

    private func jsonContent() -> Any? {
        if let dictionary = context.content as? [String: Any] { return dictionary }
        if let array = context.content as? [Any] { return array }
        if let text = context.content as? String { return text.jsonObject }
        if let node = context.content as? HTMLNode { return node.rawText.jsonObject }
        return nil
    }

    private func jsonFromValue(_ value: RuleValue) -> Any? {
        switch value {
        case .raw(let any):
            if let text = any as? String { return text.jsonObject ?? text }
            return any
        case .strings(let values):
            guard let first = values.first else { return nil }
            if values.count > 1 { return values }
            return first.jsonObject ?? first
        case .nodes(let nodes):
            return nodes.first?.rawText.jsonObject
        }
    }

    private func documentFromValue(_ value: RuleValue) -> HTMLNode? {
        switch value {
        case .nodes(let nodes):
            return nodes.first
        case .strings(let values):
            guard let first = values.first else { return nil }
            return HTMLParser.parse(first)
        case .raw(let any):
            if let node = any as? HTMLNode { return node }
            if let text = any as? String { return HTMLParser.parse(text) }
            return nil
        }
    }

    // MARK: 插值

    func interpolate(_ text: String) -> String {
        guard text.contains("{{") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let openRange = text.range(of: "{{", range: index..<text.endIndex) else {
                result += text[index...]
                break
            }
            result += text[index..<openRange.lowerBound]
            guard let closeRange = text.range(of: "}}", range: openRange.upperBound..<text.endIndex) else {
                result += text[openRange.lowerBound...]
                break
            }
            let expression = String(text[openRange.upperBound..<closeRange.lowerBound])
            result += resolveInterpolation(expression)
            index = closeRange.upperBound
        }
        return result
    }

    private func resolveInterpolation(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "page", "searchPage": return String(page)
        case "key", "searchKey":
            return key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        default: break
        }

        if trimmed.hasPrefix("book.") {
            return bookVariables[String(trimmed.dropFirst(5))] ?? ""
        }
        if trimmed.hasPrefix("chapter.") {
            return chapterVariables[String(trimmed.dropFirst(8))] ?? ""
        }
        if let value = context.getVariable?(trimmed), !value.isEmpty { return value }
        if let value = context.evaluateJS?(trimmed, nil) {
            return RuleUtil.asString(value) ?? ""
        }
        return ""
    }
}
