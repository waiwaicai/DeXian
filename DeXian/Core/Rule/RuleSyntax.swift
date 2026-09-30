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
            // <js>...</js> 是内联 JS 段，Legado 允许它出现在规则/URL 的任意位置，
            // 例：<js>java.t2s(result)</js>
// $..list[*] 或 searchUrl 的 <js>..</js>index.php?...
            if depth == 0, quote == nil, character == "<" {
                if let end = tagBlockEnd(characters, at: index, tag: "js") {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(current)
                    }
                    current = ""
                    segments.append(String(characters[index...end]))
                    index = end + 1
                    continue
                }
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

        // Legado 默认规则用 @ 串联每一步（class.item.0@tag.a@href），
        // 这些前缀本身就是明显的链分隔符。
        for prefix in ["class.", "tag.", "id.", "text.", "children"] where lowered.hasPrefix(prefix) {
            return true
        }

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
            // <js>…</js> 是内联脚本，整段跳过。
            //
            // 脚本里的 `##` / `||` 是**运算符或正则**，不是规则分隔符。
            // 实测 36小说网的正文替换规则写作
            //   <js>##36小说.*|起点中文.*|…</js><js>##(“|‘|’|…</js>
            // 不跳过就会把第一个 `##` 当成「正则##替换」的分界，
            // 规则被腰斩成 `<js>` 与半截正则 —— 后面那段再交给 JS 求值，
            // 正是日志里的 SyntaxError: Unterminated regular expression literal。
            if character == "<", let end = tagBlockEnd(characters, at: index, tag: "js") {
                index = end + 1
                continue
            }
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

    /// 顶层分隔（双竖线「取首个非空」等）。
    ///
    /// `protectJavaScript` 打开时，`@js:` 之后的内容整段不参与分隔 ——
    /// 只对规则分支（`||`）开启，见 `javascriptStart` 的说明。
    /// 按行拆分替换规则（`separator: "\n"`）等调用必须关掉它，
    /// 那里的 `\n` 是**数据分隔**，与 JS 无关。
    static func splitTopLevel(
        _ text: String,
        separator: String,
        protectJavaScript: Bool = false
    ) -> [String] {
        let separatorCharacters = Array(separator)
        let characters = Array(text)
        var results: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var index = 0
        // `@js:` 之后的部分是脚本，整段不参与分隔。
        //
        // `||` 是规则级的「取首个非空」，只适用于选择器/路径规则；
        // 脚本里的 `||` 是**逻辑或**。实测有 26 条规则（15 个源）把整个
        // 目录/封面计算写成一段 JS，脚本里自然带 `||`：
        //     @js: … re==baseUrl&&/,/.test(book.bookUrl)?re+',{…}':re
        //     @js: var chapters = json.data.chapters || []; …
        // 一旦被切开，第一段是个**残缺脚本**，往往求值成 `false`
        // （非空字符串！），于是 stringList 在第一段就命中返回，
        // 真正的地址永远算不出来 —— 界面表现是目录地址/封面变成 "false"。
        //
        // 对齐 Legado：`splitSourceRule` 把 `@js:` 之后的全部内容当作
        // 一个 Mode.Js 规则（AnalyzeRule.kt:453-454），`||` 只在 jsoup
        // 分支（AnalyzeByJSoup.getStringList）里才拆分。
        let scriptStart = protectJavaScript ? javascriptStart(characters) : nil

        while index < characters.count {
            let character = characters[index]
            // 同 findTopLevel：<js>…</js> 整体跳过，
            // 脚本里的 `||` 是逻辑或，不能当成「候选规则」的分隔。
            if character == "<", let end = tagBlockEnd(characters, at: index, tag: "js") {
                current.append(contentsOf: characters[index...end])
                index = end + 1
                continue
            }
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
            if depth == 0,
               scriptStart == nil || index < scriptStart!,
               matchesAt(characters, index, separatorCharacters) {
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

    /// 找出「顶层 `@js:`」的起始下标；没有就返回 nil。
    ///
    /// 只认引号之外、括号之外的 `@js:`，避免把字符串里的 `"@js:"` 误当成脚本起点。
    private static func javascriptStart(_ characters: [Character]) -> Int? {
        let marker: [Character] = Array("@js:")
        var depth = 0
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            // `<js>…</js>` 是独立脚本块，块内的 `@js:` 不是链式起点。
            if character == "<", let end = tagBlockEnd(characters, at: index, tag: "js") {
                index = end + 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index += 1
                continue
            }
            if character == "[" || character == "(" || character == "{" {
                depth += 1
                index += 1
                continue
            }
            if character == "]" || character == ")" || character == "}" {
                depth -= 1
                index += 1
                continue
            }
            if depth == 0, matchesAtIgnoringCase(characters, index, marker) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func matchesAt(_ characters: [Character], _ index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= characters.count else { return false }
        for offset in 0..<pattern.count where characters[index + offset] != pattern[offset] { return false }
        return true
    }

    /// 忽略 ASCII 大小写的 matchesAt（`@js:` / `@JS:` 都要认）。
    private static func matchesAtIgnoringCase(_ characters: [Character], _ index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= characters.count else { return false }
        for offset in 0..<pattern.count where !sameCharacter(characters[index + offset], pattern[offset]) {
            return false
        }
        return true
    }

    /// 按 <js>…</js> 把规则拆成「静态规则 / JS 脚本」交替的片段。
    ///
    /// 对齐 Legado 的 splitSourceRule：JS 段与静态段各自独立求值，
    /// 前一段的结果通过 result 传给下一段。
    /// 例：<js>GetTitleDecode(result); </js>
/// .search_book_data_list[*]
    static func splitJSSegments(_ rule: String) -> [(isJS: Bool, text: String)] {
        guard rule.range(of: "<js>", options: [.caseInsensitive]) != nil else {
            return [(false, rule)]
        }
        var pieces: [(Bool, String)] = []
        var cursor = rule.startIndex
        while let open = rule.range(of: "<js>", options: [.caseInsensitive], range: cursor..<rule.endIndex),
              let close = rule.range(of: "</js>", options: [.caseInsensitive], range: open.upperBound..<rule.endIndex) {
            let head = String(rule[cursor..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { pieces.append((false, head)) }
            let script = String(rule[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            pieces.append((true, script))
            cursor = close.upperBound
        }
        let tail = String(rule[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append((false, tail)) }
        return pieces
    }

    /// 判断 index 处是否是 <tag>，并返回闭合标签的下标。
    static func tagBlockEnd(_ characters: [Character], at index: Int, tag: String) -> Int? {
        let open: [Character] = Array("<" + tag + ">")
        guard index + open.count <= characters.count else { return nil }
        for offset in 0..<open.count where !sameCharacter(characters[index + offset], open[offset]) {
            return nil
        }
        let close: [Character] = Array("</" + tag + ">")
        var cursor = index + open.count
        while cursor + close.count <= characters.count {
            var matched = true
            for offset in 0..<close.count where !sameCharacter(characters[cursor + offset], close[offset]) {
                matched = false
                break
            }
            if matched { return cursor + close.count - 1 }
            cursor += 1
        }
        return nil
    }

    /// 只对 ASCII 忽略大小写，避免整串 lowercased 在非 ASCII 大写字符上错位。
    private static func sameCharacter(_ lhs: Character, _ rhs: Character) -> Bool {
        if lhs == rhs { return true }
        guard lhs.isASCII, rhs.isASCII else { return false }
        return lhs.lowercased() == rhs.lowercased()
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

    // MARK: @put / @get

    /// 摘出规则里的 `@put:{…}` 声明，返回 (剩余规则, [(变量名, 取值规则)])。
    ///
    /// 对齐 Legado 的 `splitPutRule`：`@put:` **不是规则的一部分**，
    /// 它在每次求值前被摘掉，并把声明的变量算出来存进书源变量表，
    /// 之后由同一书源其它字段里的 `@get:{…}` 读取。
    ///
    /// 语料实测（1296.json，855 个源）：57 个源用 `@put:` 声明、
    /// 204 个源用 `@get:` 读取。两者必须成对实现 —— 只读不写会让
    /// 这些源的详情页字段全部取不到值（书名 / 作者 / 简介 / 封面空白）。
    static func splitPutRule(_ rule: String) -> (core: String, puts: [(String, String)]) {
        guard rule.range(of: "@put:", options: .caseInsensitive) != nil else { return (rule, []) }
        var core = ""
        var puts: [(String, String)] = []
        var index = rule.startIndex
        while index < rule.endIndex {
            guard let open = rule.range(of: "@put:{", options: .caseInsensitive, range: index..<rule.endIndex),
                  let close = rule.range(of: "}", options: [], range: open.upperBound..<rule.endIndex) else {
                core += rule[index...]
                break
            }
            core += rule[index..<open.lowerBound]
            puts.append(contentsOf: parsePutBody(String(rule[open.upperBound..<close.lowerBound])))
            index = close.upperBound
        }
        return (core, puts)
    }

    /// 解析 `@put:` 的花括号内容。
    ///
    /// 写法与 Legado 一致：宽松的 JSON 对象，键可以带引号也可以裸写，
    /// 值是一条规则（可能含 `##` 替换、`|` 选择器、换行）。
    /// 语料里的实际形态：
    ///     {"bid":"$.id"}
    ///     {id:$.novelid||$.novelId}
    ///     {n:"[property$=book_name]@content", a:"[property$=author]@content"}
    private static func parsePutBody(_ body: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for entry in splitTopLevel(body, separator: ",") {
            guard let colon = firstTopLevelColon(entry) else { continue }
            let key = unquote(String(entry[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines))
            let value = unquote(String(entry[entry.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            guard !key.isEmpty, !value.isEmpty else { continue }
            result.append((key, value))
        }
        return result
    }

    /// 找到第一个不在引号 / 括号里的冒号（键值分隔符）。
    private static func firstTopLevelColon(_ text: String) -> String.Index? {
        var depth = 0
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "[" || character == "(" || character == "{" {
                depth += 1
            } else if character == "]" || character == ")" || character == "}" {
                depth -= 1
            } else if character == ":", depth == 0 {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 去掉一层包裹的引号（JSON 语法，不属于规则本身）。
    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        let first = text.first
        guard first == "\"" || first == "'" else { return text }
        guard text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// 找到规则里第一处 `@get:{key}`。
    static func firstGetSubstitution(_ rule: String) -> (range: Range<String.Index>, key: String)? {
        guard let open = rule.range(of: "@get:{", options: .caseInsensitive),
              let close = rule.range(of: "}", options: [], range: open.upperBound..<rule.endIndex) else {
            return nil
        }
        let key = String(rule[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (open.lowerBound..<close.upperBound, key)
    }

    /// 把规则里所有 `@get:{key}` 换成取值闭包给出的文本。
    static func expandGets(_ rule: String, value: (String) -> String) -> String {
        guard rule.range(of: "@get:", options: .caseInsensitive) != nil else { return rule }
        var output = ""
        var index = rule.startIndex
        while index < rule.endIndex {
            guard let open = rule.range(of: "@get:{", options: .caseInsensitive, range: index..<rule.endIndex),
                  let close = rule.range(of: "}", options: [], range: open.upperBound..<rule.endIndex) else {
                output += rule[index...]
                break
            }
            output += rule[index..<open.lowerBound]
            let key = String(rule[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            output += value(key)
            index = close.upperBound
        }
        return output
    }
}
