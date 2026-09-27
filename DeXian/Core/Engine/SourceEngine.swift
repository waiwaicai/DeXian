import Foundation

/// 单本书源的抓取引擎：把书源规则跑成真实数据。
///
/// 流程与 Legado 对齐：
/// 搜索/发现 -> 详情页 -> 目录 -> 正文，
/// 每一步都用 AnalyzeRule 求值规则，用 JSEngine 执行 @js。
final class SourceEngine {

    let source: BookSource
    /// 书籍级共享变量（对应 book.variable，用于存 bookId 之类）
    let variables: VariableStore
    private lazy var headers: [String: String] = parseHeaders()
    /// 音频书源解析出的直链缓存，按章节地址区分（音源通常只返回一次）
    private var audioCache: [String: String] = [:]

    init(source: BookSource, variables: [String: String] = [:]) {
        self.source = source
        self.variables = VariableStore(variables)
    }

    /// 当前变量快照，便于持久化到书架
    var variableSnapshot: [String: String] { variables.snapshot }

    var sourceKey: String { source.id }

    // MARK: 搜索

    func search(keyword: String, page: Int = 1) async throws -> [SearchBook] {
        let request = source.resolvedSearchRequest
        guard !request.url.isEmpty else { throw SourceError.missingSearchUrl }

        let js = makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
        js.key = keyword
        js.page = page

        // URL 里可能内嵌 @js / <js> 段（例：<js>if(page==1){…}</js>index.php?…）
        let urlTemplate = RuleUtil.resolveJSSegments(request.url) { script in
            RuleUtil.asString(js.evaluate(script)) ?? ""
        }

        let analyzer = makeAnalyzer(content: nil, baseUrl: source.url, js: js)
        analyzer.key = keyword
        analyzer.page = page
        let urlString = analyzer.interpolate(urlTemplate)

        let response = try await performRequest(
            urlString: urlString,
            options: request.options,
            page: page,
            keyword: keyword
        )
        let listAnalyzer = makeAnalyzer(content: response.text, baseUrl: urlString, js: js)
        listAnalyzer.page = page
        listAnalyzer.key = keyword

        let items = listAnalyzer.listItems(source.searchRule.bookList)
        let books = items.compactMap { item in
            buildSearchBook(item: item, rule: source.searchRule, baseUrl: urlString, js: js, page: page, keyword: keyword)
        }
        return dedupe(books)
    }

    // MARK: 发现

    func explore(urlTemplate: String, page: Int = 1) async throws -> [SearchBook] {
        let js = makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
        js.page = page

        let analyzer = makeAnalyzer(content: nil, baseUrl: source.url, js: js)
        analyzer.page = page
        var resolved = analyzer.interpolate(urlTemplate)
        resolved = RuleUtil.resolveJSSegments(resolved) { script in
            RuleUtil.asString(js.evaluate(script)) ?? ""
        }

        let parsed = HTTPClient.parseURLRule(resolved)
        var options = parsed.options
        options.method = options.method.isEmpty ? "GET" : options.method

        let content = try await fetchContent(urlString: parsed.url, options: options, page: page, keyword: "")

        let listAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        listAnalyzer.page = page
        let items = listAnalyzer.listItems(source.exploreRule.bookList)
        let books = items.compactMap { item in
            buildSearchBook(item: item, rule: source.exploreRule.asSearchRule, baseUrl: parsed.url, js: js, page: page, keyword: "")
        }
        return dedupe(books)
    }

    // MARK: 详情页

    func bookInfo(bookUrl: String, bookInfo: [String: String] = [:]) async throws -> BookInfo {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: [:], title: "")
        let analyzer = makeAnalyzer(content: nil, baseUrl: bookUrl, js: js)

        // 有些源详情页需要 POST 或 JS 生成 URL
        var target = bookUrl
        if target.hasPrefix("@js:") || target.hasPrefix("<js>") {
            let (kind, body) = RuleSyntax.detectKind(target)
            _ = kind
            target = js.evaluateString(body)
        }

        let content = try await fetchContent(urlString: target, options: HTTPRequestOptions(), page: 1, keyword: "")
        let document = HTMLParser.parse(content)

        // init 规则可改写内容
        var workingContent: Any = content
        if let initRule = source.bookInfoRule.initRule, !initRule.isEmpty {
            let initAnalyzer = makeAnalyzer(content: content, baseUrl: target, js: js)
            let initValue = initAnalyzer.string(initRule)
            if !initValue.isEmpty { workingContent = initValue }
        }

        let detailAnalyzer = makeAnalyzer(content: workingContent, baseUrl: target, js: js)
        _ = document

        var info = BookInfo()
        info.name = detailAnalyzer.string(source.bookInfoRule.name)
        info.author = detailAnalyzer.string(source.bookInfoRule.author)
        info.kind = detailAnalyzer.string(source.bookInfoRule.kind).nilIfBlank
        info.wordCount = detailAnalyzer.string(source.bookInfoRule.wordCount).nilIfBlank
        info.lastChapter = detailAnalyzer.string(source.bookInfoRule.lastChapter).nilIfBlank
        info.intro = detailAnalyzer.string(source.bookInfoRule.intro).nilIfBlank
        let cover = detailAnalyzer.string(source.bookInfoRule.coverUrl)
        info.coverUrl = RuleUtil.absoluteURL(cover, base: target).nilIfBlank
        let toc = detailAnalyzer.string(source.bookInfoRule.tocUrl)
        info.tocUrl = toc.isEmpty ? nil : RuleUtil.absoluteURL(toc, base: target)
        return info
    }

    // MARK: 目录

    func toc(tocUrl: String, bookInfo: [String: String] = [:]) async throws -> [BookChapter] {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: [:], title: "")
        let analyzer = makeAnalyzer(content: nil, baseUrl: tocUrl, js: js)
        var target = analyzer.interpolate(tocUrl)

        var content = try await fetchContent(urlString: target, options: HTTPRequestOptions(), page: 1, keyword: "")
        var listAnalyzer = makeAnalyzer(content: content, baseUrl: target, js: js)
        var items = listAnalyzer.listItems(source.tocRule.chapterList)

        var chapters: [BookChapter] = []
        var index = 0
        for item in items {
            let itemAnalyzer = makeAnalyzer(content: item, baseUrl: target, js: js)
            let title = itemAnalyzer.string(source.tocRule.chapterName)
            let chapterURL = itemAnalyzer.string(source.tocRule.chapterUrl)
            guard !title.isEmpty || !chapterURL.isEmpty else { continue }
            chapters.append(BookChapter(
                url: RuleUtil.absoluteURL(chapterURL, base: target),
                title: title.isEmpty ? "第" + String(index + 1) + "章" : title,
                index: index,
                isVip: !itemAnalyzer.string(source.tocRule.isVip).isEmpty,
                updateTime: itemAnalyzer.string(source.tocRule.updateTime).nilIfBlank,
                tag: nil, start: nil, end: nil, variable: nil
            ))
            index += 1
        }

        // 翻页目录
        var nextURL = listAnalyzer.string(source.tocRule.nextTocUrl)
        var pageCount = 0
        while !nextURL.isEmpty, pageCount < 20 {
            pageCount += 1
            let resolvedNext = RuleUtil.absoluteURL(analyzer.interpolate(nextURL), base: target)
            guard let nextContent = try? await fetchContent(urlString: resolvedNext, options: HTTPRequestOptions(), page: pageCount + 1, keyword: "") else { break }
            let nextAnalyzer = makeAnalyzer(content: nextContent, baseUrl: resolvedNext, js: js)
            let nextItems = nextAnalyzer.listItems(source.tocRule.chapterList)
            if nextItems.isEmpty { break }
            for item in nextItems {
                let itemAnalyzer = makeAnalyzer(content: item, baseUrl: resolvedNext, js: js)
                let title = itemAnalyzer.string(source.tocRule.chapterName)
                let chapterURL = itemAnalyzer.string(source.tocRule.chapterUrl)
                guard !title.isEmpty || !chapterURL.isEmpty else { continue }
                chapters.append(BookChapter(
                    url: RuleUtil.absoluteURL(chapterURL, base: resolvedNext),
                    title: title.isEmpty ? "第" + String(index + 1) + "章" : title,
                    index: index,
                    isVip: false, updateTime: nil, tag: nil, start: nil, end: nil, variable: nil
                ))
                index += 1
            }
            let following = nextAnalyzer.string(source.tocRule.nextTocUrl)
            if following == nextURL { break }
            nextURL = following
            target = resolvedNext
        }

        guard !chapters.isEmpty else { throw SourceError.emptyToc }
        return chapters
    }

    // MARK: 正文

    /// 抓取章节正文。返回 (正文, 图片链接, 下一章地址)
    func content(
        chapterUrl: String,
        bookInfo: [String: String] = [:],
        chapterInfo: [String: String] = [:],
        chapterTitle: String = ""
    ) async throws -> ChapterContent {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: chapterInfo, title: chapterTitle)
        let analyzer = makeAnalyzer(content: nil, baseUrl: chapterUrl, js: js)
        var target = analyzer.interpolate(chapterUrl)

        if target.hasPrefix("@js:") {
            target = js.evaluateString(String(target.dropFirst(4)))
        }

        let parsed = HTTPClient.parseURLRule(target)
        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "")

        // baseUrl 对齐当前页面地址，页面匹配类脚本（baseUrl.match(...)）才正确
        js.host.baseUrl = parsed.url

        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        var text = contentAnalyzer.string(source.contentRule.content)

        // 图片链接（漫画 / 插图）
        var images = extractImages(from: text, baseUrl: parsed.url)

        // 正文翻页
        var nextURLString = contentAnalyzer.string(source.contentRule.nextContentUrl)
        var pageCount = 0
        while !nextURLString.isEmpty, pageCount < 10 {
            pageCount += 1
            let nextURL = RuleUtil.absoluteURL(analyzer.interpolate(nextURLString), base: parsed.url)
            guard let nextContent = try? await fetchContent(urlString: nextURL, options: HTTPRequestOptions(), page: pageCount + 1, keyword: "") else { break }
            let nextAnalyzer = makeAnalyzer(content: nextContent, baseUrl: nextURL, js: js)
            let nextText = nextAnalyzer.string(source.contentRule.content)
            if nextText.isEmpty { break }
            text += "\n" + nextText
            images.append(contentsOf: extractImages(from: nextText, baseUrl: nextURL))
            let following = nextAnalyzer.string(source.contentRule.nextContentUrl)
            if following == nextURLString { break }
            nextURLString = following
        }

        // sourceRegex 二次截取
        if let sourceRegex = source.contentRule.sourceRegex, !sourceRegex.isEmpty, !text.isEmpty {
            if let matched = RuleUtil.regexFirst(text, pattern: sourceRegex) {
                text = matched
            }
        }

        // 正文净化
        text = cleanContent(text)
        images = dedupeImages(images)

        return ChapterContent(text: text, images: images, nextChapterUrl: nil).normalized()
    }

    /// 音频（听书）：取出章节对应的音频直链
    ///
    /// 音源站点常见三种情况：
    /// 1. 正文规则直接给出音频地址；
    /// 2. 正文是一段播放器代码，需要从里面匹配 .mp3 / .m4a 等链接；
    /// 3. 接口只允许解析一次，因此把结果缓存起来复用。
    func audioURL(
        chapterUrl: String,
        bookInfo: [String: String] = [:],
        chapterInfo: [String: String] = [:],
        chapterTitle: String = ""
    ) async throws -> String {
        if let cached = audioCache[chapterUrl], !cached.isEmpty { return cached }

        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: chapterInfo, title: chapterTitle)
        let analyzer = makeAnalyzer(content: nil, baseUrl: chapterUrl, js: js)
        var target = analyzer.interpolate(chapterUrl)
        if target.hasPrefix("@js:") {
            target = js.evaluateString(String(target.dropFirst(4)))
        }

        let parsed = HTTPClient.parseURLRule(target)
        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "")
        js.host.baseUrl = parsed.url
        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)

        var candidates: [String] = []

        // 正文规则的结果本身就是地址
        let direct = contentAnalyzer.string(source.contentRule.content)
        candidates.append(contentsOf: RuleUtil.extractURLs(direct))
        candidates.append(contentsOf: audioLinks(in: direct, baseUrl: parsed.url))

        // 规则没命中时，退回整页扫描
        if candidates.isEmpty {
            candidates.append(contentsOf: audioLinks(in: content, baseUrl: parsed.url))
        }

        // 兜底：JSON 形式返回的音频字段
        if candidates.isEmpty {
            for key in ["url", "src", "audio", "playUrl", "musicUrl", "mp3"] {
                let value = contentAnalyzer.string("$." + key)
                guard !value.isEmpty else { continue }
                candidates.append(contentsOf: audioLinks(in: value, baseUrl: parsed.url))
            }
        }

        guard let first = candidates.first(where: { !$0.isEmpty }) else {
            throw SourceError.emptyContent
        }
        audioCache[chapterUrl] = first
        return first
    }

    /// 从文本中匹配常见音频链接
    private func audioLinks(in value: String, baseUrl: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let pattern = "(?:https?:)?//[^\\s\"'<>\\,]+?\\.(?:mp3|m4a|aac|ogg|flac|wav|m3u8)"
        let matched = RuleUtil.regexMatch(value, pattern: pattern)
        return matched.map { RuleUtil.absoluteURL($0, base: baseUrl) }
    }

    /// 漫画：把章节内所有图片按顺序取出
    func comicImages(chapterUrl: String, bookInfo: [String: String] = [:], chapterInfo: [String: String] = [:]) async throws -> [String] {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: chapterInfo, title: "")
        let analyzer = makeAnalyzer(content: nil, baseUrl: chapterUrl, js: js)
        let target = analyzer.interpolate(chapterUrl)
        let parsed = HTTPClient.parseURLRule(target)

        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "")
        js.host.baseUrl = parsed.url
        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        var value = contentAnalyzer.string(source.contentRule.content)
        if value.isEmpty { value = content }

        var images = extractImages(from: value, baseUrl: parsed.url)

        // 翻页
        var nextURLString = contentAnalyzer.string(source.contentRule.nextContentUrl)
        var pageCount = 0
        while !nextURLString.isEmpty, pageCount < 10 {
            pageCount += 1
            let nextURL = RuleUtil.absoluteURL(analyzer.interpolate(nextURLString), base: parsed.url)
            guard let nextContent = try? await fetchContent(urlString: nextURL, options: HTTPRequestOptions(), page: pageCount + 1, keyword: "") else { break }
            let nextAnalyzer = makeAnalyzer(content: nextContent, baseUrl: nextURL, js: js)
            let nextValue = nextAnalyzer.string(source.contentRule.content)
            images.append(contentsOf: extractImages(from: nextValue.isEmpty ? nextContent : nextValue, baseUrl: nextURL))
            let following = nextAnalyzer.string(source.contentRule.nextContentUrl)
            if following == nextURLString { break }
            nextURLString = following
        }
        return dedupeImages(images)
    }

    // MARK: 请求

    private func fetchContent(
        urlString: String,
        options incomingOptions: HTTPRequestOptions,
        page: Int,
        keyword: String
    ) async throws -> String {
        guard !urlString.isEmpty else { throw SourceError.emptyURL }
        let js = makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
        js.page = page
        js.key = keyword

        var options = incomingOptions
        var target = urlString

        // URL 内的 js 改写：url,{"js":"..."}
        if let range = urlString.range(of: ",{\"js\"") {
            target = String(urlString[..<range.lowerBound])
            let optionText = String(urlString[range.lowerBound...].dropFirst())
            if let dictionary = optionText.jsonObject as? [String: Any] {
                for (key, value) in dictionary { options.headers[key] = RuleUtil.asString(value) ?? "" }
                if let script = dictionary.str("js") {
                    js.host.baseUrl = target
                    _ = js.evaluate(script)
                    if let mutated = js.host.baseUrl.nilIfBlank { target = mutated }
                }
            }
        }

        let analyzer = makeAnalyzer(content: nil, baseUrl: target, js: js)
        analyzer.page = page
        analyzer.key = keyword
        target = analyzer.interpolate(target)

        let response = try await HTTPClient.shared.request(
            urlString: target,
            options: options,
            sourceKey: source.cookieJar ? source.id : nil,
            defaultHeaders: headers,
            base: baseForResolving(target, fallback: source.url)
        )

        // 登录检查
        if let check = source.loginCheckJs.nilIfBlank {
            js.host.document = HTMLParser.parse(response.text)
            js.src = response.text
            _ = js.evaluate(check)
        }
        return response.text
    }

    private func performRequest(
        urlString: String,
        options: HTTPRequestOptions,
        page: Int,
        keyword: String
    ) async throws -> HTTPResponse {
        guard !urlString.isEmpty else { throw SourceError.emptyURL }
        let js = makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
        js.key = keyword
        js.page = page
        let analyzer = makeAnalyzer(content: nil, baseUrl: source.url, js: js)
        analyzer.key = keyword
        analyzer.page = page
        let target = analyzer.interpolate(urlString)

        let parsed = HTTPClient.parseURLRule(target)
        var finalOptions = options
        finalOptions.method = options.method == "GET" && parsed.options.method != "GET" ? parsed.options.method : options.method
        if let body = parsed.options.body, options.body == nil { finalOptions.body = body }
        for (key, value) in parsed.options.headers where options.headers[key] == nil {
            finalOptions.headers[key] = value
        }

        let response = try await HTTPClient.shared.request(
            urlString: parsed.url,
            options: finalOptions,
            sourceKey: source.cookieJar ? source.id : nil,
            defaultHeaders: headers,
            base: baseForResolving(parsed.url, fallback: source.url)
        )

        if let check = source.loginCheckJs.nilIfBlank {
            js.host.document = HTMLParser.parse(response.text)
            js.src = response.text
            _ = js.evaluate(check)
        }
        return response
    }

    // MARK: 辅助构建

    /// 构造 JS 引擎并注入宿主回调
    private func makeJSEngine(
        content: Any?,
        bookInfo: [String: String],
        chapterInfo: [String: String],
        title: String
    ) -> JSEngine {
        var host = JSEngine.Host()
        host.sourceKey = source.id
        host.sourceName = source.name
        host.baseUrl = source.url
        host.headers = headers
        host.bookInfo = bookInfo
        host.chapterInfo = chapterInfo
        host.title = title
        host.variables = variables
        host.document = content as? HTMLNode

        let js = JSEngine(host: host)
        js.src = (content as? String) ?? ""

        // 让 java.getString / java.setContent 回到规则引擎
        js.host.resolveString = { [weak js] rule, target, _ in
            guard let js else { return "" }
            return SourceEngine.makeAnalyzer(
                content: target ?? content,
                baseUrl: js.host.baseUrl,
                js: js,
                bookInfo: bookInfo,
                chapterInfo: chapterInfo
            ).string(rule)
        }
        js.host.resolveStringList = { [weak js] rule, target, _ in
            guard let js else { return [] }
            return SourceEngine.makeAnalyzer(
                content: target ?? content,
                baseUrl: js.host.baseUrl,
                js: js,
                bookInfo: bookInfo,
                chapterInfo: chapterInfo
            ).stringList(rule)
        }

        if !source.jsLib.isEmpty {
            js.loadJsLib(source.jsLib)
        }
        return js
    }

    /// 构造规则求值器（把 JS 能力接进规则链）
    private func makeAnalyzer(content: Any?, baseUrl: String?, js: JSEngine) -> AnalyzeRule {
        SourceEngine.makeAnalyzer(
            content: content,
            baseUrl: baseUrl,
            js: js,
            bookInfo: js.host.bookInfo,
            chapterInfo: js.host.chapterInfo
        )
    }

    /// 规则求值器工厂：JS 宿主回调需要它，因此做成静态方法。
    static func makeAnalyzer(
        content: Any?,
        baseUrl: String?,
        js: JSEngine,
        bookInfo: [String: String],
        chapterInfo: [String: String]
    ) -> AnalyzeRule {
        var context = RuleContext(content: content, baseUrl: baseUrl)
        context.evaluateJS = { [weak js] script, previous in
            if let previous { js?.result = previous } else { js?.result = content }
            return js?.evaluate(script)
        }
        context.getVariable = { [weak js] name in
            if let value = js?.variable(named: name), !value.isEmpty { return value }
            if let value = bookInfo[name], !value.isEmpty { return value }
            return chapterInfo[name] ?? ""
        }
        context.putVariable = { [weak js] name, value in
            js?.setVariable(name, value: value ?? "")
        }
        let analyzer = AnalyzeRule(context: context)
        analyzer.bookVariables = bookInfo
        analyzer.chapterVariables = chapterInfo
        return analyzer
    }

    /// 把列表条目（HTML 节点 / JSON 对象）转成 SearchBook
    private func buildSearchBook(
        item: Any,
        rule: SearchRule,
        baseUrl: String,
        js: JSEngine,
        page: Int,
        keyword: String
    ) -> SearchBook? {
        let analyzer = makeAnalyzer(content: item, baseUrl: baseUrl, js: js)
        analyzer.page = page
        analyzer.key = keyword

        let name = analyzer.string(rule.name)
        let bookURL = analyzer.string(rule.bookUrl)
        guard !name.isEmpty || !bookURL.isEmpty else { return nil }

        let author = analyzer.string(rule.author)
        let cover = analyzer.string(rule.coverUrl)

        return SearchBook(
            name: name.isEmpty ? "未命名" : name,
            author: author,
            kind: analyzer.string(rule.kind).nilIfBlank,
            wordCount: analyzer.string(rule.wordCount).nilIfBlank,
            lastChapter: analyzer.string(rule.lastChapter).nilIfBlank,
            intro: analyzer.string(rule.intro).nilIfBlank,
            coverUrl: RuleUtil.absoluteURL(cover, base: baseUrl).nilIfBlank,
            bookUrl: RuleUtil.absoluteURL(bookURL, base: baseUrl),
            origin: source.id,
            originName: source.name,
            type: BookType(rawValue: source.type.rawValue) ?? .text
        )
    }

    /// 去重并限制条目数量。
    ///
    /// SearchBook.id 是「源 id + 书籍地址」拼出来的，书源规则写得松时
    /// 很容易出现重复地址；SwiftUI 的 ForEach 遇到重复 id 会直接崩
    /// （Fatal error: Duplicate ID），必须在这里兜住。
    /// 同时限制单源结果上限，避免某个源返回上万条把界面卡死。
    private func dedupe(_ books: [SearchBook]) -> [SearchBook] {
        var seen = Set<String>()
        var result: [SearchBook] = []
        for book in books {
            guard seen.insert(book.id).inserted else { continue }
            result.append(book)
            if result.count >= 500 { break }
        }
        return result
    }

    /// 相对地址的解析基准。
    ///
    /// 书源里 "/search.php?searchkey={{key}}"、"a.jpg" 这类相对写法很常见，
    /// 目标已是绝对地址时 base 不参与计算，直接返回 nil。
    private func baseForResolving(_ urlString: String, fallback: String) -> String? {
        let value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return fallback.nilIfBlank }
        if value.hasPrefix("//") || RuleUtil.hasScheme(value) { return nil }
        return fallback.nilIfBlank
    }

    private func parseHeaders() -> [String: String] {
        let raw = source.header.trimmed
        guard !raw.isEmpty else { return [:] }
        if raw.hasPrefix("@js:") || raw.hasPrefix("<js>") { return [:] }
        if let dictionary = raw.jsonObject as? [String: Any] {
            var result: [String: String] = [:]
            for (key, value) in dictionary {
                let lowered = key.lowercased()
                if lowered == "proxy" || lowered == "webview" { continue }
                result[key] = RuleUtil.asString(value) ?? ""
            }
            return result
        }
        return [:]
    }

    // MARK: 正文清洗

    func cleanContent(_ text: String) -> String {
        var result = text

        // 应用书源自定义的正文替换规则（Legado 的 替换净化）
        if let replaceRule = source.contentRule.replaceRegex?.nilIfBlank {
            for rule in RuleSyntax.splitTopLevel(replaceRule, separator: "\n") {
                // 支持 "正则##替换" 与 "正则" 两种写法
                if let range = rule.range(of: "##") {
                    let pattern = String(rule[..<range.lowerBound])
                    let replacement = String(rule[range.upperBound...])
                    if !pattern.isEmpty {
                        result = RuleUtil.regexReplace(result, pattern: pattern, replacement: replacement)
                    }
                } else {
                    result = RuleUtil.regexReplace(result, pattern: rule, replacement: "")
                }
            }
        }

        result = result.replacingOccurrences(of: "\u{00a0}", with: " ")
        result = RuleUtil.cleanText(result)

        // 去掉常见广告尾巴（对齐阅读的“净化”行为，但只做通用且安全的处理）
        let adPatterns = [
            "本章未完，请点击下一页继续阅读",
            "请记住本站域名",
            "手机版阅读网址",
            "加入书签，方便阅读",
            "最快更新，无弹窗阅读"
        ]
        for pattern in adPatterns {
            result = result.replacingOccurrences(of: pattern, with: "")
        }

        // 统一段落
        result = HTMLNode.collapseNewlines(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从正文 HTML / 文本中提取图片链接
    func extractImages(from value: String, baseUrl: String) -> [String] {
        var results: [String] = []

        // 先按 HTML 解析取 img 标签的常见属性
        if value.contains("<img") {
            let document = HTMLParser.parse(value)
            let nodes = CSSSelector.select("img", in: document)
            for node in nodes {
                for attribute in ["src", "data-src", "data-original", "data-echo", "data-url", "data-lazy-src", "data-cfsrc"] {
                    if let raw = node.attribute(attribute), !raw.isEmpty,
                       !raw.hasPrefix("data:image/gif"), !raw.hasPrefix("data:image/svg") {
                        results.append(RuleUtil.absoluteURL(raw, base: baseUrl))
                        break
                    }
                }
            }
        }

        // JS 规则常返回 [{link:"..."}] 这类对象数组（包子漫画等）
        if results.isEmpty, value.contains("{") {
            for raw in RuleUtil.imageLinksFromJSON(value) {
                results.append(RuleUtil.absoluteURL(raw, base: baseUrl))
            }
        }

        // 再兜底扫描裸链接
        if results.isEmpty {
            let candidates = RuleUtil.regexMatch(value, pattern: "(?:https?:)?//[^\\s\"'<>,]+?\\.(?:jpg|jpeg|png|webp|gif|bmp|avif)")
            results = candidates.map { RuleUtil.absoluteURL($0, base: baseUrl) }
        }

        // 过滤掉明显的占位图 / 广告位
        return results.filter { url in
            let lowered = url.lowercased()
            if lowered.contains("loading") || lowered.contains("blank.gif") { return false }
            if lowered.contains("ad.") || lowered.contains("/ads/") { return false }
            return true
        }
    }

    private func dedupeImages(_ images: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for image in images where seen.insert(image).inserted { result.append(image) }
        return result
    }
}

/// 章节正文结果
struct ChapterContent: Codable {
    var text: String
    var images: [String]
    var nextChapterUrl: String?

    func normalized() -> ChapterContent {
        var value = self
        value.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}

enum SourceError: LocalizedError {
    case missingSearchUrl
    case emptyURL
    case emptyToc
    case emptyContent
    case sourceDisabled

    var errorDescription: String? {
        switch self {
        case .missingSearchUrl: return "该源不支持搜索"
        case .emptyURL: return "地址为空"
        case .emptyToc: return "目录获取失败"
        case .emptyContent: return "正文获取失败"
        case .sourceDisabled: return "书源已禁用"
        }
    }

    /// 把系统英文错误翻成中文，方便在搜索页一眼看出原因。
    static func describe(_ error: Error) -> String {
        if let source = error as? SourceError { return source.errorDescription ?? "书源错误" }
        if let network = error as? NetworkError { return network.errorDescription ?? "网络错误" }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "系统拦截了明文 http（ATS）"
        case NSURLErrorTimedOut: return "请求超时"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "域名解析失败"
        case NSURLErrorCannotConnectToHost: return "无法连接服务器"
        case NSURLErrorNetworkConnectionLost: return "网络连接中断"
        case NSURLErrorNotConnectedToInternet: return "当前无网络"
        case NSURLErrorUnsupportedURL: return "链接格式不支持"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return "HTTPS 证书校验失败"
        case NSURLErrorCancelled: return "请求已取消"
        default: return ns.localizedDescription
        }
    }
}

extension ExploreRule {
    /// 发现规则与搜索规则字段一致，统一转换。
    var asSearchRule: SearchRule {
        var rule = SearchRule()
        rule.bookList = bookList
        rule.name = name
        rule.author = author
        rule.kind = kind
        rule.wordCount = wordCount
        rule.lastChapter = lastChapter
        rule.intro = intro
        rule.coverUrl = coverUrl
        rule.bookUrl = bookUrl
        return rule
    }
}
