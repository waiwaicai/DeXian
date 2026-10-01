import Foundation

/// 订阅源（RSS）抓取引擎。
///
/// 订阅源与书源的规则语法完全一致，因此这里直接复用 AnalyzeRule / JSEngine，
/// 只把"目录 -> 正文"换成"文章列表 -> 文章正文"。
final class RssEngine {

    let source: RssSource
    private lazy var headers: [String: String] = parseHeaders()

    init(source: RssSource) {
        self.source = source
    }

    // MARK: 文章列表

    /// 抓取一页文章列表。
    /// - Parameters:
    ///   - urlTemplate: 分类地址（空则用订阅源主页），支持 {{page}} / JS 段
    ///   - page: 页码
    func articles(urlTemplate: String, page: Int = 1) async throws -> RssPage {
        let js = makeJSEngine(content: nil)
        js.page = page
        let analyzer = makeAnalyzer(content: nil, baseUrl: source.url, js: js)
        analyzer.page = page

        var target = analyzer.interpolate(urlTemplate.trimmed.isEmpty ? source.url : urlTemplate)
        target = RuleUtil.resolveJSSegments(target) { script in
            RuleUtil.asString(js.evaluate(script)) ?? ""
        }
        let parsed = HTTPClient.parseURLRule(target)
        var options = parsed.options
        options.method = options.method.isEmpty ? "GET" : options.method

        let content = try await fetch(urlString: parsed.url, options: options)

        // 没有 ruleArticles 的源（如"源仓库官方纯净"）：直接把页面里的链接当作文章
        guard source.hasArticleRule else {
            return RssPage(
                articles: fallbackArticles(html: content, baseUrl: parsed.url, js: js),
                nextPageURL: resolveNextPage(html: content, baseUrl: parsed.url, page: page, js: js)
            )
        }

        let listAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        listAnalyzer.page = page
        let items = listAnalyzer.listItems(source.ruleArticles)
        var results: [RssArticle] = []
        var seen = Set<String>()
        for item in items {
            guard let article = buildArticle(item: item, baseUrl: parsed.url, js: js, page: page) else { continue }
            let key = article.link + "|" + article.title
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(article)
        }
        return RssPage(
            articles: results,
            nextPageURL: resolveNextPage(html: content, baseUrl: parsed.url, page: page, js: js)
        )
    }

    /// 从当前列表页解析"下一页"地址（对应 Legado 的 ruleNextPage）。
    ///
    /// 只接受真正不同、且能拼成绝对地址的结果，避免规则为空/原地打转时死循环。
    private func resolveNextPage(html: String, baseUrl: String, page: Int, js: JSEngine) -> String? {
        let rule = source.ruleNextPage.trimmed
        guard !rule.isEmpty else { return nil }
        let analyzer = makeAnalyzer(content: html, baseUrl: baseUrl, js: js)
        analyzer.page = page
        var value = analyzer.string(rule).trimmed
        guard !value.isBlank else { return nil }
        value = RuleUtil.resolveJSSegments(value) { script in
            RuleUtil.asString(js.evaluate(script)) ?? ""
        }.trimmed
        guard !value.isBlank else { return nil }
        let resolved = RuleUtil.absoluteURL(value, base: baseUrl)
        guard !resolved.isBlank, resolved != baseUrl else { return nil }
        return resolved
    }

    // MARK: 文章正文

    /// 抓取一篇文章的正文（HTML），供阅读界面渲染。
    func articleContent(link: String, title: String = "") async throws -> String {
        let js = makeJSEngine(content: nil)
        js.host.title = title
        let analyzer = makeAnalyzer(content: nil, baseUrl: link, js: js)

        var target = analyzer.interpolate(link)
        target = RuleUtil.resolveJSSegments(target) { script in
            RuleUtil.asString(js.evaluate(script)) ?? ""
        }
        let parsed = HTTPClient.parseURLRule(target)
        var options = parsed.options
        options.method = options.method.isEmpty ? "GET" : options.method

        let content = try await fetch(urlString: parsed.url, options: options)
        guard !source.ruleContent.trimmed.isEmpty else { return content }

        // 凹凸吧这类源用 HTML 模板声明正文，其中 `{{@@selector@html}}`
        // 是插入解析结果，而不是一条普通抽取规则。AnalyzeRule 只能返回文本，
        // 会丢掉 img/a/iframe；这里按模板片段单独解析。
        if source.ruleContent.contains("{{") {
            return renderContentTemplate(from: content, baseUrl: parsed.url, js: js)
        }

        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        let value = contentAnalyzer.string(source.ruleContent)
        return value.isBlank ? content : value
    }

    private func renderContentTemplate(from content: String, baseUrl: String, js: JSEngine) -> String {
        let analyzer = makeAnalyzer(content: content, baseUrl: baseUrl, js: js)
        let raw = analyzer.string("{{@@#rawContent@html}}")
        let template = source.ruleContent
        var result = ""
        var cursor = template.startIndex
        while let range = template.range(of: "{{", range: cursor..<template.endIndex) {
            result += template[cursor..<range.lowerBound]
            guard let close = template.range(of: "}}", range: range.upperBound..<template.endIndex) else {
                result += template[range.lowerBound...]
                cursor = template.endIndex
                break
            }
            let expression = String(template[range.upperBound..<close.lowerBound])
            let selector = expression.hasPrefix("@@") ? String(expression.dropFirst(2)) : expression
            let pieces = selector.components(separatedBy: "@")
            let rule = pieces.first ?? selector
            let outputMode = pieces.count > 1 ? pieces[1].lowercased() : "text"
            if rule == "#rawContent" {
                result += raw
            } else if outputMode.contains("html") || outputMode.contains("all") {
                result += analyzer.string("{{@@\(rule)@html}}")
            } else {
                result += analyzer.string(rule)
            }
            cursor = close.upperBound
        }
        result += template[cursor...]
        return result.isBlank ? raw : result
    }

    // MARK: 搜索

    func search(keyword: String, page: Int = 1) async throws -> [RssArticle] {
        let raw = source.searchUrl.trimmed
        guard !raw.isEmpty else { throw SourceError.missingSearchUrl }
        let js = makeJSEngine(content: nil)
        js.key = keyword
        js.page = page
        let analyzer = makeAnalyzer(content: nil, baseUrl: source.url, js: js)
        analyzer.key = keyword
        analyzer.page = page

        var target = analyzer.interpolate(raw)
        target = RuleUtil.resolveJSSegments(target) { script in
            RuleUtil.asString(js.evaluate(script)) ?? ""
        }
        let parsed = HTTPClient.parseURLRule(target)
        var options = parsed.options
        options.method = options.method.isEmpty ? "GET" : options.method

        let content = try await fetch(urlString: parsed.url, options: options)
        guard source.hasArticleRule else {
            return fallbackArticles(html: content, baseUrl: parsed.url, js: js)
        }
        let listAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        listAnalyzer.key = keyword
        listAnalyzer.page = page
        return listAnalyzer.listItems(source.ruleArticles).compactMap {
            buildArticle(item: $0, baseUrl: parsed.url, js: js, page: page, keyword: keyword)
        }
    }

    // MARK: 构建

    private func buildArticle(
        item: Any,
        baseUrl: String,
        js: JSEngine,
        page: Int,
        keyword: String = ""
    ) -> RssArticle? {
        let analyzer = SourceEngine.makeAnalyzer(
            content: item,
            baseUrl: baseUrl,
            js: js,
            bookInfo: [:],
            chapterInfo: [:]
        )
        analyzer.page = page
        analyzer.key = keyword

        let title = analyzer.string(source.ruleTitle).trimmed
        let link = analyzer.string(source.ruleLink).trimmed
        guard !title.isEmpty || !link.isEmpty else { return nil }
        // 只有链接没标题时，用链接末段兜底
        let finalTitle = title.isEmpty ? (URL(string: link)?.lastPathComponent ?? link) : title

        let image = analyzer.string(source.ruleImage)
        return RssArticle(
            title: finalTitle,
            link: RuleUtil.absoluteURL(link, base: baseUrl),
            pubDate: analyzer.string(source.rulePubDate).trimmed,
            summary: analyzer.string(source.ruleDescription).trimmed,
            imageUrl: RuleUtil.absoluteURL(image, base: baseUrl),
            origin: source.id,
            originName: source.name
        )
    }

    /// 无规则源：抽取页面里看起来像文章链接的条目。
    private func fallbackArticles(html: String, baseUrl: String, js: JSEngine) -> [RssArticle] {
        let document = HTMLParser.parse(html)
        let nodes = CSSSelector.select("a", in: document)
        var results: [RssArticle] = []
        var seen = Set<String>()
        for node in nodes {
            guard let href = node.attribute("href"), !href.isBlank else { continue }
            let lowered = href.lowercased()
            if lowered.hasPrefix("javascript:") || lowered.hasPrefix("#") { continue }
            let link = RuleUtil.absoluteURL(href, base: baseUrl)
            guard !link.isBlank, !seen.contains(link) else { continue }
            let text = node.normalizedText.trimmed
            if text.isEmpty { continue }
            seen.insert(link)
            results.append(RssArticle(
                title: text,
                link: link,
                pubDate: "",
                summary: "",
                imageUrl: "",
                origin: source.id,
                originName: source.name
            ))
        }
        return results
    }

    // MARK: 网络

    private func fetch(urlString: String, options: HTTPRequestOptions) async throws -> String {
        guard !urlString.isBlank else { throw SourceError.emptyURL }
        do {
            let response = try await HTTPClient.shared.request(
                urlString: urlString,
                options: options,
                sourceKey: source.enabledCookieJar ? source.id : nil,
                defaultHeaders: headers,
                base: source.url.trimmed.isEmpty ? nil : source.url
            )
            return response.text
        } catch {
            // 一批订阅源仍声明 http://，但站点已只支持 https://。
            // 只在第一次请求失败时升级重试，避免正常请求翻倍。
            guard let url = URL(string: urlString), url.scheme?.lowercased() == "http" else { throw error }
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw error }
            var upgradedComponents = components
            upgradedComponents.scheme = "https"
            guard let upgraded = upgradedComponents.string else { throw error }
            let response = try await HTTPClient.shared.request(
                urlString: upgraded,
                options: options,
                sourceKey: source.enabledCookieJar ? source.id : nil,
                defaultHeaders: headers,
                base: source.url.trimmed.isEmpty ? nil : source.url
            )
            return response.text
        }
    }

    private func parseHeaders() -> [String: String] {
        let raw = source.header.trimmed
        guard !raw.isEmpty, raw.hasPrefix("{") else { return [:] }
        guard let dictionary = raw.jsonObject as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            let lowered = key.lowercased()
            if lowered == "proxy" || lowered == "webview" { continue }
            result[key] = RuleUtil.asString(value) ?? ""
        }
        return result
    }

    // MARK: 构建

    private func makeJSEngine(content: Any?) -> JSEngine {
        var host = JSEngine.Host()
        host.sourceKey = source.id
        host.sourceName = source.name
        host.baseUrl = source.url
        host.sourceUrl = source.url
        host.sourceComment = source.comment
        host.sourceHeader = source.header
        host.loginUrl = source.loginUrl
        host.headers = headers
        host.document = content as? HTMLNode

        // 订阅源声明原样透传：脚本直接读 source.sourceIcon（51 处）/
        // source.sourceComment（135 处）/ source.sortUrl（17 处）等字段。
        // 缺失时是 undefined，`obj.img = source.sourceIcon` 会把整列封面写成
        // "undefined" 字符串。解析失败（旧数据没有这一列）时留空字典，
        // 行为与改动前一致。
        if let metaJSON = source.metaJSON, !metaJSON.isEmpty,
           let data = metaJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            host.sourceMeta = parsed
        }

        let js = JSEngine(host: host)
        js.src = (content as? String) ?? ""
        js.sourceVariable = SourceVariableStore.shared[source.id] ?? ""
        js.onVariableChanged = { value in
            SourceVariableStore.shared[engine.source.id] = value
        }
        js.host.resolveString = { [weak js] rule, target, _ in
            guard let js else { return "" }
            return SourceEngine.makeAnalyzer(
                content: target ?? content,
                baseUrl: js.host.baseUrl,
                js: js,
                bookInfo: [:],
                chapterInfo: [:]
            ).string(rule)
        }
        js.host.resolveStringList = { [weak js] rule, target, _ in
            guard let js else { return [] }
            return SourceEngine.makeAnalyzer(
                content: target ?? content,
                baseUrl: js.host.baseUrl,
                js: js,
                bookInfo: [:],
                chapterInfo: [:]
            ).stringList(rule)
        }
        if !source.jsLib.isEmpty { js.loadJsLib(source.jsLib) }
        return js
    }

    private func makeAnalyzer(content: Any?, baseUrl: String?, js: JSEngine) -> AnalyzeRule {
        SourceEngine.makeAnalyzer(content: content, baseUrl: baseUrl, js: js, bookInfo: [:], chapterInfo: [:])
    }
}

/// 一页文章列表 + 下一页地址
struct RssPage {
    var articles: [RssArticle]
    var nextPageURL: String?
}

/// 订阅源里的一篇文章
struct RssArticle: Codable, Hashable, Identifiable {
    var id: String { link + "|" + title + "|" + origin }
    var title: String
    var link: String
    var pubDate: String
    var summary: String
    var imageUrl: String
    var origin: String
    var originName: String
}
