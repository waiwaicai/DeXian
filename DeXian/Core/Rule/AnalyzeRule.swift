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

    /// 保留段落的文本形态：块级标签产生换行，<br> 产生换行。
    /// 与 strings 的区别仅在于节点集合的处理方式。
    var paragraphStrings: [String] {
        switch self {
        case .nodes(let nodes):
            return nodes.map { $0.textWithBreaks }
        case .strings(let values):
            return values
        case .raw(let any):
            if let list = any as? [Any] { return list.map { RuleUtil.asString($0) ?? "" } }
            return RuleUtil.asString(any).map { [$0] } ?? []
        }
    }

    var isEmpty: Bool {
        switch self {
        case .nodes(let nodes): return nodes.isEmpty
        case .strings(let values): return values.isEmpty
        case .raw(let any): return RuleUtil.asString(any)?.isEmpty ?? true
        }
    }

    /// 供 JS 的 result 变量使用。
    ///
    /// `result` 的形态**取决于这条规则求的是什么**，这一点与 Legado 一致：
    ///
    /// - 列表规则（书架列表 / 目录列表，走 `listItems`）在 Legado 里是
    ///   `AnalyzeRule.getElements`，中间值给 JS 的是 **jsoup 元素对象**。
    ///   书源据此写 `result.toArray()` / `result.select('a')`。
    /// - 文本规则（书名 / 正文 / 作者，走 `string`、`stringList`）在 Legado 里
    ///   是 `getString` / `getStringList`，中间值给 JS 的是 **字符串**。
    ///   书源据此写 `result.match(…)` / `result.replace(…)`。
    ///
    /// 所以这里必须按调用方区分，不能一刀切：列表规则传节点，
    /// 文本规则传文本。传错的后果分别是
    /// "result.match is not a function" 与 "result.toArray is not a function"。
    func jsValue(elements: Bool) -> Any? {
        switch self {
        case .nodes(let nodes):
            guard elements else {
                let values = nodes.map { XPathEngine.stringValue(of: $0) }
                // 文本规则一律给**字符串**，多条匹配用换行拼接。
                //
                // 对齐 Legado：AnalyzeRule.getString 先把 jsoup 结果
                // joinToString("\n") 成字符串，再把该字符串交给 Mode.Js 步骤
                // （AnalyzeRule.kt:249-254 的 `result = evalJS(rule, it)`，
                // 此处 it 已是 getString 的字符串结果）。
                //
                // 旧实现在「命中多条」时给数组，脚本里的
                //     result.match(/\d+?.\d+万/g)[0]
                // 就变成 "result.match is not a function"，整条规则作废 ——
                // 实测量产日志里这一类报错 54 条中占很大比重，
                // 界面表现是「字数/分类/简介空着」以及「正文整段看不到」。
                // 实测 3460 个源里，文本字段对 result 调字符串方法的规则有 280 条，
                // 而对 result 调数组方法的只有 0 条，因此这里必须给字符串。
                return values.count == 1 ? values[0] : values.joined(separator: "\n")
            }
            return nodes.count == 1 ? nodes[0] : nodes
        case .strings(let values):
            // 同 .nodes：文本场景给字符串，列表场景（JSON 路径选出多条）
            // 必须保持数组 —— 书源写 `$.items[:10]<js> result.toArray() …`，
            // 把数组 join 成字符串会让 toArray/concat/map 全部失效。
            guard !elements else {
                return values.count == 1 ? values[0] : values
            }
            return values.count == 1 ? values[0] : values.joined(separator: "\n")
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

    /// 正文抽取模式：节点结果按块级标签保留换行，段落不再被压平
    /// 只在解析正文时开启；搜索/目录等短字段仍用纯文本。
    var paragraphs = false

    /// 文本字段取值（对齐 Legado 的 getString）。
    ///
    /// 关键：多条匹配必须换行合并，而不是只取第一条。
    ///
    /// 正文规则绝大多数是「选中一整组段落」的写法，例如
    /// `@css:div.read-content p@text`，它会命中列表里所有 <p>。
    /// 只取第一条的话整章正文只剩开头几个字 ——
    /// 用户看到的「打开只显示几个字 / 只显示一半」就是这里来的。
    /// Legado 的行为是 getStringList(rule).joinToString("\n")，对齐它。
    func string(_ rule: String?) -> String {
        stringList(rule).joined(separator: "\n")
    }

    /// 单值字段取值（对齐 Legado 的 getString0 / isUrl 分支）。
    ///
    /// 地址类字段（书籍地址 / 目录地址 / 下一页地址 / 封面）天然只有一个值。
    /// 若把多条匹配用换行拼起来，会得到一段根本无法访问的地址，
    /// 因此这些调用点必须走这里，而不是 string()。
    func firstString(_ rule: String?) -> String {
        stringList(rule).first ?? ""
    }

    func stringList(_ rule: String?) -> [String] {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        for branch in RuleSyntax.splitTopLevel(rule, separator: "||", protectJavaScript: true) {
            let value = evaluateRule(branch, elements: false)
            // 正文抽取时保留段落：节点结果若直接拼接子文本，
            // <p>…</p><p>…</p> 会被压成一整行，阅读时排版全乱。
            // 列表 / 标题等短字段仍走纯文本，避免书名里混进换行。
            let strings = (paragraphs ? value.paragraphStrings : value.strings)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // 单条字符串结果按换行再拆一层（对齐 Legado 的
            // ``if (result is String) result = result.split("\n")``）。
            //
            // 书源里有大量「JS 里 join("\n") 拼出一串条目」的写法，
            // 例如目录：``<js>…list.join("\n")</js>``。
            // 不拆的话整串只算一个条目，界面表现就是「章节不全」。
            // 文本字段走 string() 时会用 "\n" 回拼，内容不受影响。
            //
            // 只在「结果为单条字符串」时拆，与 Legado 的 `result is String` 一致：
            // 多条目结果本身就已是逐条分开的，再拆一次会把条目内部
            // 本来就存在的换行（如正文段落）误当成条目分界。
            var expanded = strings
            if !paragraphs, strings.count == 1, strings[0].contains("\n") {
                expanded = strings[0].components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if !expanded.isEmpty { return expanded }
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
        for branch in RuleSyntax.splitTopLevel(rule, separator: "||", protectJavaScript: true) {
            let value = evaluateRule(branch, elements: false)
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
        for branch in RuleSyntax.splitTopLevel(rule, separator: "||", protectJavaScript: true) {
            let items = evaluateListRule(branch)
            if !items.isEmpty { return items }
        }
        return []
    }

    // MARK: 规则链

    /// 求值单条规则（含 @ 链与内嵌 <js> 段）。
    ///
    /// `elements` 表示这条规则是否在求列表（见 `RuleValue.jsValue(elements:)`）：
    /// 列表规则要把节点原样交给 JS 当元素用，文本规则要给字符串。
    private func evaluateRule(_ rule: String, elements: Bool) -> RuleValue {
        var text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .strings([]) }

        // `@put:{…}` 不是规则的一部分，先摘出来落地成变量（对齐 Legado 的
        // splitPutRule + putRule）。实测 57 个书源用它声明详情页字段，
        // 204 个书源用 @get:{…} 读取 —— 只读不写会让这些源的书名 / 作者 /
        // 简介 / 封面 / 目录地址全部为空。
        let (withoutPuts, puts) = RuleSyntax.splitPutRule(text)
        if !puts.isEmpty {
            applyPuts(puts)
            text = withoutPuts.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .strings([]) }
        }

        let (core, replacements) = RuleSyntax.splitReplaceRule(text)
        var value = evaluateChained(core, elements: elements)
        if !replacements.isEmpty {
            value = .strings(applyReplacements(value.strings, replacements: replacements))
        }
        return value
    }

    /// 落地 `@put:{…}` 声明的变量。
    ///
    /// 取值一律按「文本规则」求值（对齐 Legado 的 putRule → getString），
    /// 结果写进书源变量表，供同一书源其它字段的 `@get:{…}` 读取。
    private func applyPuts(_ puts: [(String, String)]) {
        for (name, rule) in puts {
            context.putVariable?(name, string(rule))
        }
    }

    /// 规则是否以「选择器 / 路径」记号开头（而不是纯模板文本）。
    private static func startsWithRuleMarker(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        for prefix in ["class.", "tag.", "id.", "text.", "children", "@css:", "@xpath:",
                       "@json:", "@regex:", "@@", "$.", "$[", "//", "/html", "/body", "("] {
            if value.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// 规则的主体是不是一段 **JavaScript**。
    ///
    /// 上面那条「含 `{{…}}` 就当文本」的捷径对 `@js:` / `<js>` 必须让路，
    /// 否则整段脚本会被当成一段普通字符串返回 —— 界面表现是
    /// 「这个源的书 / 目录 / 正文是空的，或者直接显示了一段脚本原文」。
    ///
    /// 实测 3460 个源里有 111 条规则（57 个源）命中：
    ///     @js: `../chapter?id={{$.id}}`  → 模板串里带插值
    ///     <js> java.t2s(getString('text') || `{{book.name}}`) </js>
    ///     @js: java.timeFormatUTC({{$.time}}, "yyyy-MM-dd", 0)
    ///
    /// 这些规则里的 `{{…}}` 是**给脚本用的值**，必须先替换成实际内容
    /// 再交给 JS 求值（`expanded` 已经做过替换），而不是把整段原样吐出。
    private static func startsWithJSMarker(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("@js:") || value.hasPrefix("<js>")
    }

    /// 求值规则；内嵌 <js>…</js> 段先跑，其结果作为后续规则的输入。
    private func evaluateChained(_ text: String, elements: Bool) -> RuleValue {
        let pieces = RuleSyntax.splitJSSegments(text)
        guard pieces.count > 1 else {
            var segments = RuleSyntax.splitChain(text)
            guard !segments.isEmpty else { return .strings([]) }
            // 规则以链式 `@` 开头（例：`@href` / `@text` / `@a@href`）时，
            // 开头会产生一个空段。对齐 Legado 的 AnalyzeRule.trim()：那里
            // 把开头的 `@` 吞掉，规则落在当前节点上。
            //
            // 旧实现直接把空段交给 evaluateBase，求值成空数组，
            // 后续链式又作用在空数组上，结果恒为空 —— 实测 72 条规则这么写，
            // 集中在目录的 chapterName / chapterUrl，表现是
            // 「目录名 / 章节地址整列取不到」。
            //
            // Legado 的语序是「除最后一段外都是选择器，最后一段取属性/文本」
            // （AnalyzeByJSoup.getResultList + getResultLast），因此：
            //   `@href`     → 当前节点 + 取 href
            //   `@a@href`   → 当前节点下选 a + 取 href
            // 两者必须区别对待，不能一律当链式记号。
            var base: RuleValue
            var startIndex = 0
            if segments[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.removeFirst()
                if segments.count <= 1 {
                    // 只剩一段：作用于当前节点，该段按链式记号处理
                    return applyToCurrentContext(segments.first ?? "", elements: elements)
                } else {
                    // 还有多段：第一段是选择器，其余按链式处理
                    base = evaluateBase(segments[0])
                    startIndex = 1
                }
            } else {
                base = evaluateBase(segments[0])
                startIndex = 1
            }
            var value = base
            for segment in segments.dropFirst(startIndex) {
                value = applyTransform(segment, to: value, elements: elements)
            }
            return value
        }

        var value = RuleValue.strings([])
        for (isJS, piece) in pieces {
            if isJS {
                let result = runInterpolatedJS(piece, previous: value.isEmpty ? nil : value.jsValue(elements: elements))
                value = .raw(result ?? "")
            } else {
                value = evaluateSegment(piece, previous: value, elements: elements)
            }
        }
        return value
    }

    /// 求值一段静态规则。
    ///
    /// 前面没有 JS 结果时按普通规则（可能含 @ 链）求值；
    /// 已有 JS 结果时，对齐 Legado：以该结果为内容重新起一条规则，
    /// 例 `<js>GetList(result)</js>$.data.list[*]`。
    private func evaluateSegment(_ piece: String, previous: RuleValue, elements: Bool) -> RuleValue {
        let segments = RuleSyntax.splitChain(piece)
        guard !segments.isEmpty else { return previous }
        if previous.isEmpty {
            var value = evaluateBase(segments[0])
            for segment in segments.dropFirst() { value = applyTransform(segment, to: value, elements: elements) }
            return value
        }
        // 链式记号（@href / @text / @js: 等）直接作用在上一段结果上
        if segments.count == 1, isTransformMarker(segments[0]) {
            return applyTransform(segments[0], to: previous, elements: elements)
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
        for segment in segments.dropFirst() { value = nested.applyTransform(segment, to: value, elements: elements) }
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
        // 列表规则：`result` 交给 JS 时保持元素形态（对齐 Legado 的 getElements）
        let value = evaluateChained(core, elements: true)
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

        // 单条字符串结果按换行拆开（对齐 Legado 的
        // ``if (result is String) result = result.split("\n")``）。
        //
        // 目录规则里常见 ``<js>…list.join("\n")</js>`` 这类写法：
        // JS 返回的是「一整串用换行拼起来的章节」。Legado 会把整串拆成条目，
        // 不拆就只算一条，界面上表现为「章节不全 / 目录只有一条」。
        //
        // 只在**结果为单条字符串**时才拆：多条目结果本身已经是逐条分开的
        // （节点列表 / 字符串数组），此时把每一项再拆一次反而会把正文
        // 强行切碎 —— 那是「正文被截断」的另一种成因。
        if items.count == 1, let text = items[0] as? String, text.contains("\n") {
            items = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
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
        // `@get:{key}` 取的是同书源 `@put:{…}` 存下的变量（对齐 Legado 的
        // makeUpRule）。它可能出现在纯规则、URL 模板，甚至 JS 片段里
        // （实测 2 处写在 <js> 内），所以统一在进入规则识别之前展开，
        // 这样三种位置都能拿到值。
        let expanded = RuleSyntax.expandGets(interpolated) { key in
            context.getVariable?(key) ?? ""
        }
        guard !expanded.isBlank else { return .strings([]) }

        // 含 `{{…}}` / `@get:{…}}` 的规则，替换完成后结果是**文本**，
        // 不能再当成选择器去求值。
        //
        // 对齐 Legado：`SourceRule` 初始化时若匹配到 evalPattern
        // （即 `@get:{…}` / `{{…}}`），会把 mode 置为 Regex
        // （AnalyzeRule.kt:527-533），也就是「把替换后的内容当文本用」，
        // 而不是当 CSS/XPath 选择器。
        //
        // 书源普遍这么写详情页字段：
        //     @get:{n}s            → 书名文本
        //     {{$.id}}             → 书籍编号
        //     {{book.name}}        → 书名
        // 若再走一遍选择器，整段文本会被当成一个 CSS 选择器，
        // 一条都匹配不到 —— 表现就是书名 / 作者 / 简介全空。
        // 只在这条规则**除了模板记号之外没有别的规则语法**时才当文本。
        // 少数规则是「选择器/JSON 路径 + 模板」的组合，例如
        //     $[?(@.chapter_name=="{{chapter.title}}")]
        // 展开后仍要按 JSON 路径求值，不能拍成文本。
        if (text.contains("{{") || text.lowercased().contains("@get:")),
           !Self.startsWithRuleMarker(text),
           !Self.startsWithJSMarker(text) {
            return .strings([expanded])
        }

        let (kind, body) = RuleSyntax.detectKind(expanded)

        switch kind {
        case .javascript:
            // 走插值版：`<js>…{{book.name}}…</js>` 这类脚本里的模板记号
            // 必须先替换成实际内容，否则会原样留在字符串里。
            let value = runInterpolatedJS(body)
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
            return .strings(applyRegexRule(expanded))

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
            return .strings([expanded])
        }
    }

    /// 链式转换（@ 之后的段）
    private func applyTransform(_ segment: String, to value: RuleValue, elements: Bool) -> RuleValue {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return value }
        let lowered = text.lowercased()

        if lowered.hasPrefix("js:") {
            let script = String(text.dropFirst(3))
            let result = runInterpolatedJS(script, previous: value.jsValue(elements: elements))
            return .raw(result ?? "")
        }
        if lowered.hasPrefix("@js:") {
            let script = String(text.dropFirst(4))
            let result = runInterpolatedJS(script, previous: value.jsValue(elements: elements))
            return .raw(result ?? "")
        }
        if lowered.hasPrefix("<js>") {
            let (kind, body) = RuleSyntax.detectKind(text)
            guard kind == .javascript else { return value }
            let result = runInterpolatedJS(body, previous: value.jsValue(elements: elements))
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

    /// 求值一段 JS，但**先展开脚本里的 `{{…}}` / `@get:{…}`**。
    ///
    /// 书源大量把模板插值写在脚本内部，指望它先被替换成实际内容再求值：
    ///
    /// ```js
    /// @js: `../chapter?id={{$.id}}&offset=0` + new Date().getTime()
    /// <js> java.t2s(getString('text') || `{{book.name}}`) </js>
    /// @js: java.timeFormatUTC({{$.time}}, "yyyy-MM-dd", 0)
    /// ```
    ///
    /// 不展开就直接交给 JS 时，`{{…}}` 会被解析成**嵌套对象字面量**
    /// （`{{a:1}}` 是合法的 JS 表达式），于是脚本不报错、但算出来的是
    /// `[object Object]` 之类的垃圾 —— 比报错更难排查。
    /// 实测 3460 个源里有 111 条规则（57 个源）这么写。
    ///
    /// `interpolate` 内部对 `{{}}` 与 `@get:{}` 都是文本替换，
    /// 因此对脚本同样适用；替换后的字面量若含引号等字符，由书源自己负责转义
    /// （Legado 的 makeUpRule 也是直接拼接文本，行为一致）。
    private func runInterpolatedJS(_ script: String, previous: Any? = nil) -> Any? {
        guard script.contains("{{") || script.lowercased().contains("@get:") else {
            return runJS(script, previous: previous)
        }
        return runJS(interpolate(script), previous: previous)
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

    /// 当前内容作为规则值。
    ///
    /// 用于「规则以链式 `@` 开头」的情形：Legado 的 AnalyzeRule.trim() 会把
    /// 开头那个 `@` 吞掉，规则直接作用在当前节点/内容上，
    /// 因此 `@href` / `@text` 取的是**当前节点本身**的属性或文本。
    ///
    /// 节点与文档统一包成 .nodes（选择器求值的自然形态）；
    /// 其余内容（JSON 对象 / 字符串）原样透传，交由后续链式记号处理。
    private func currentContextValue() -> RuleValue {
        if let node = context.content as? HTMLNode { return .nodes([node]) }
        if let nodes = context.content as? [HTMLNode] { return .nodes(nodes) }
        if let document = context.document { return .nodes([document]) }
        // 注意不能写 `.raw(context.content as Any)`：content 是 Any?，
        // 包成 Any 之后 `Optional.none` 会变成「非 nil 的 Any」，
        // 后续 asString 会走进容器分支得到 "null" 之类的垃圾文本。
        guard let content = context.content else { return .strings([]) }
        return .raw(content)
    }

    /// 把一段链式记号作用在**当前内容**上（规则以 `@` 开头时）。
    ///
    /// 两种语义都要支持，且优先「取属性 / 取文本」这类真正的链式记号：
    ///
    /// - `@href` / `@text` / `@title` → 取当前节点的属性或文本；
    /// - `@baseUrl` → 书源里表示「当前页面地址」，是个变量而不是属性名。
    ///   属性缺失时若退回节点文本，会得到一大段 HTML 拼出的假地址，
    ///   请求必然失败。实测 📂知妖 / 168TXT 两个源用 `@baseUrl` 当目录地址。
    /// - `@a@href` 这种「先选子元素再取属性」由调用方的多段分支处理，
    ///   不会走到这里（这里只处理**只剩一段**的情况）。
    private func applyToCurrentContext(_ segment: String, elements: Bool) -> RuleValue {
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return currentContextValue() }
        if text.lowercased() == "baseurl", let baseUrl = context.baseUrl, !baseUrl.isEmpty {
            return .strings([baseUrl])
        }
        return applyTransform(text, to: currentContextValue(), elements: elements)
    }

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
        // `@get:{key}` 也可能直接写在 URL 模板里
        // （例：`https://h5.17k.com/list/@get:{id}.html`），
        // 与 {{…}} 一样属于求值前必须替换掉的记号。
        let source = RuleSyntax.expandGets(text) { key in
            context.getVariable?(key) ?? ""
        }
        guard source.contains("{{") else { return source }
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard let openRange = source.range(of: "{{", range: index..<source.endIndex) else {
                result += source[index...]
                break
            }
            result += source[index..<openRange.lowerBound]
            guard let closeRange = source.range(of: "}}", range: openRange.upperBound..<source.endIndex) else {
                result += source[openRange.lowerBound...]
                break
            }
            let expression = String(source[openRange.upperBound..<closeRange.lowerBound])
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

        // {{...}} 里以 @ / $. / $[ / // 开头的是**规则**，不是 JavaScript。
        //
        // 这是 Legado 的既有约定（AnalyzeRule.isRule：js 首个字符不可能是 @，
        // 所以 @ 开头一律当规则）。实测书源里有 {{@@h1@text}}、{{$.id}} 这类写法。
        // 旧实现把这些整串丢给 JSEngine 求值，@ 在 JS 里是非法字符，
        // 于是每个字段都报 SyntaxError: Invalid character: '@' 并退化成空串
        // （用户看到的就是「内容分类里无显示」）。
        if isRuleExpression(trimmed) {
            return string(trimmed)
        }

        if let value = context.evaluateJS?(trimmed, nil) {
            return RuleUtil.asString(value) ?? ""
        }
        return ""
    }

    /// {{}} 插值里的一段文本是不是「规则」（而不是 JS 表达式）。
    ///
    /// 与 Legado AnalyzeRule.isRule 保持一致：
    /// @开头（含 @@ / @js: / @xpath: 等）、美元路径、// 开头的 XPath。
    private func isRuleExpression(_ text: String) -> Bool {
        text.hasPrefix("@") || text.hasPrefix("$.") || text.hasPrefix("$[") || text.hasPrefix("//")
    }
}
