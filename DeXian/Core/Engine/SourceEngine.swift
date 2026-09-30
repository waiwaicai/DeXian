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

    /// 请求头缓存。
    ///
    /// 不能用 lazy var：同一个 SourceEngine 会被并发使用
    /// （阅读时 preloadNeighbors 会同时预取后两章，缓存整本也会复用同一引擎），
    /// 而 Swift 的 lazy 初始化不是线程安全的，两边同时首次访问会触发
    /// 内存冲突直接崩溃。这里改成显式加锁的一次性初始化。
    private let headersLock = NSLock()
    private var cachedHeaders: [String: String]?
    private var headers: [String: String] {
        headersLock.lock()
        if let cachedHeaders {
            headersLock.unlock()
            return cachedHeaders
        }
        headersLock.unlock()
        let value = parseHeaders()
        headersLock.lock()
        cachedHeaders = value
        headersLock.unlock()
        return value
    }

    /// 音频书源解析出的直链缓存，按章节地址区分（音源通常只返回一次）
    private var audioCache: [String: String] = [:]
    private let audioLock = NSLock()

    // MARK: 表单型发现源的回调（由发现页注入）
    //
    // 「🔍搜索」按钮走 java.searchBook，要把关键词交回界面去开搜索页；
    // 「切换频道」按钮走 java.refreshExplore，要让发现页重新求值；
    // java.toast 要让用户看到提示。引擎只负责转发。
    var onSearchBook: ((String) -> Void)?
    var onRefreshExplore: (() -> Void)?
    var onToast: ((String) -> Void)?

    /// 兼容层新增的宿主回调（由阅读页 / 发现页注入）。
    ///
    /// - onRefreshRequest：脚本调用 refreshTocUrl / refreshBookUrl /
    ///   refreshContent 等刷新类 API 时通知界面重新拉取（733 个源在用）。
    /// - onLoginInfoChanged：upLoginData / putLoginInfo 保存登录信息。
    /// - onRequestLogin：脚本要求弹出登录 / 验证界面。
    /// - onOpenVideo：openVideoPlayer 把视频直链交给播放器。
    /// - onAddBook：java.addBook(url) 跳转书籍。
    /// - onClipboard：java.setClipboard(text) 写剪贴板（诊断用）。
    /// - onReverseTocChanged：book.setReverseToc(bool) 切换目录正反序。
    /// - onBookTypeChanged：book.setType(int) 影视源改书籍类型。
    var onRefreshRequest: ((String) -> Void)?
    var onLoginInfoChanged: (([String: String]) -> Void)?
    var onRequestLogin: (() -> Void)?
    var onOpenVideo: ((String, String) -> Void)?
    var onAddBook: ((String) -> Void)?
    var onClipboard: ((String) -> Void)?
    var onReverseTocChanged: ((Bool) -> Void)?
    var onBookTypeChanged: ((Int) -> Void)?

    /// 书源登录信息（脚本 putLoginInfo / upLoginData 写入）。
    private(set) var sourceLoginInfo: [String: String] = [:]

    /// 脚本请求「重新拉取」的标记。
    ///
    /// `java.refreshTocUrl()` / `refreshBookUrl()` / `refreshContent()` 的语义是
    /// 「当前缓存已失效，下次请重新请求」。这些调用发生在 JS 求值**内部**，
    /// 此时直接发起新请求会重入求值（同一次阅读里目录规则自己再触发一次目录请求），
    /// 实测就是「刷目录时卡住然后闪退」。
    /// 因此这里只登记，由调用方在本次操作结束后取走执行。
    private let refreshLock = NSLock()
    private var pendingRefreshNames: Set<String> = []

    /// 非空表示脚本要求刷新对应资源（"toc" / "book" / "content" / "info"）。
    func consumePendingRefresh() -> Set<String> {
        refreshLock.lock(); defer { refreshLock.unlock() }
        let value = pendingRefreshNames
        pendingRefreshNames = []
        return value
    }

    private func markPendingRefresh(_ name: String) {
        refreshLock.lock()
        pendingRefreshNames.insert(Self.refreshCategory(name))
        refreshLock.unlock()
    }

    /// 把 API 名归一成资源类别。
    private static func refreshCategory(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("toc") { return "toc" }
        if lowered.contains("content") { return "content" }
        if lowered.contains("info") { return "info" }
        if lowered.contains("book") { return "book" }
        return "all"
    }

    /// 测试入口：把一次刷新请求登记进待办（生产路径由 onRefreshRequest 触发）。
    func registerPendingRefreshForTesting(_ name: String) {
        markPendingRefresh(name)
    }

    /// 测试入口：在完整的宿主环境里求值一段脚本，返回其字符串结果。
    ///
    /// 生产路径不存在「只求值一段脚本」的调用（规则都经 AnalyzeRule），
    /// 因此单独开这个口子给单元测试验证 source.* / book.* 的注入是否到位。
    func evaluateScript(_ script: String) -> String {
        makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
            .evaluateString(script)
    }


    /// 书籍级上下文（目录规模 / 阅读进度 / 书籍类型）。
    ///
    /// 书源脚本会读 `book.durChapterIndex`（880 个源）、
    /// `book.totalChapterNum`（619 个源）、`book.canUpdate`（362 个源）
    /// 来判断「这一章是不是当前在读章」「是不是最后一章」。
    /// 不注入时它们是 undefined：`chapter.index == undefined` 恒为 false，
    /// 依赖这个判断的正文分支整段走空 —— 表现是「打开显示几个字 / 显示一半」。
    struct BookContext {
        var url: String = ""
        var type: Int = 0
        var durChapterIndex: Int = 0
        var durChapterTitle: String = ""
        var totalChapterNum: Int = 0
        var canUpdate: Bool = true
        var customIntro: String = ""
        var latestChapterTitle: String = ""
        var status: String = ""
        var reverseToc: Bool = false
        /// 书架序号（Legado 的 book.order）：0 表示不在书架/未分组。
        var order: Int = 0
    }

    private let bookContextLock = NSLock()
    private var storedBookContext = BookContext()

    var bookContext: BookContext {
        get {
            bookContextLock.lock(); defer { bookContextLock.unlock() }
            return storedBookContext
        }
        set {
            bookContextLock.lock()
            storedBookContext = newValue
            bookContextLock.unlock()
        }
    }

    /// 视频书源解析出的直链缓存。
    ///
    /// 与音频分开持有：同一本书可能同时挂着音频源与影视源，
    /// 共用一个字典会互相覆盖。
    private var videoCache: [String: String] = [:]
    private let videoLock = NSLock()

    /// 取页面 / 请求用的兜底 JS 引擎。
    ///
    /// 正常路径下调用方都会把自己已经建好的引擎传进来（见 fetchContent 的 js 参数），
    /// 一本漫画翻几十页只用一个 JSVirtualMachine。原先每一步都新建一个，
    /// 几十页就能堆出几十个虚拟机，是「一直加载中然后闪退」的主要内存来源。
    /// 这里只在调用方没传时才现建，保证兼容性。
    private func makePlumbingJS() -> JSEngine {
        makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
    }

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

        // JS 里的全局 baseUrl 必须指向**真实请求地址**。
        //
        // 实测书源大量用 baseUrl 参与规则计算（听小说APP 用
        // `String(baseUrl).split('/audiolist-4/')` 取书号、起点用
        // `baseUrl.match(/\/(\d+)\//)` 取书籍 id）。baseUrl 停在书源入口域名时
        // 这些计算全部落空，规则静默返回空串 —— 界面表现就是
        // 「目录获取失败」「听书打不开」。旧实现只在抓页面时设过一次，
        // 规则求值阶段拿到的仍是 source.url。
        js.host.baseUrl = urlString

        let response = try await performRequest(
            urlString: urlString,
            options: request.options,
            page: page,
            keyword: keyword,
            js: js
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

    /// 执行表单控件的 action 脚本（按钮点击 / 下拉框切换）。
    ///
    /// 脚本一律通过全局 `infoMap` 读用户当前的选择，所以这里要先把
    /// 界面上的控件值灌进 infoMap 再求值。返回脚本输出，便于测试断言。
    @discardableResult
    func evaluateFormAction(_ action: String, values: [String: String]) -> String {
        let script = action.trimmed
        guard !script.isEmpty else { return "" }
        let js = makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
        // 先把控件值写进 infoMap：脚本马上会读它
        for (key, value) in values {
            js.setFormValue(key, value: value)
        }
        let output = js.evaluateString(script)
        return output
    }

    /// 求值「发现页配置」：得到分类按钮与表单控件。
    ///
    /// exploreUrl 有两种形态，旧实现只处理了第一种：
    /// 1. 静态文本 —— "玄幻::/a\n都市::/b" 或一个 JSON 数组字面量；
    /// 2. 脚本体 —— `@js:` / `<js>`，**运行时**才生成列表。
    ///
    /// 第二种实测 136 个源，其中 5 个（七猫·API / 奈飞工厂 / 听小说APP /
    /// 吉站漫画 / 终极全栖接口聚合）返回的是「下拉框 + 搜索按钮」这种表单，
    /// 一部分项没有 url。旧实现把整串当文本解析，既不会执行脚本、也没有
    /// 表单模型，于是发现页只剩零星几条 —— 用户看到的就是
    /// 「内容分类里也无显示，都打不开」。
    func explorePage() -> ExplorePage {
        let raw = source.exploreUrl.trimmed
        guard !raw.isEmpty else { return ExplorePage(categories: [], controls: []) }

        let (kind, body) = RuleSyntax.detectKind(raw)
        // 静态文本（含 "::" 列表或 JSON 数组字面量）不需要 JS
        if kind != .javascript {
            return ExplorePage.parse(raw)
        }

        let js = makeJSEngine(content: nil, bookInfo: [:], chapterInfo: [:], title: "")
        // body 已经是裸脚本（@js: / <js> 的前缀都被 detectKind 剥掉了），
        // 直接求值。不能再跑一遍 resolveJSSegments：脚本字符串里出现
        // "@js:" 字样时会被误判成「整串要重新求值」，反而把脚本吃掉。
        // 脚本内部可能真的发请求（露西弗同人站会拉排行榜接口），这里允许。
        let output = js.evaluateString(body)
        if output.trimmed.isEmpty {
            // 脚本没输出：返回空页。
            //
            // 不能退回 ExplorePage.parse(raw) —— 那会把整段脚本当成
            // 「单条地址」，界面出现一个叫「全部」的入口，点下去拿
            // 36415 字符的脚本文本去发请求。宁可为空，也不要造出假分类。
            return ExplorePage(categories: [], controls: [])
        }
        return ExplorePage.parse(output)
    }

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

        // 同 search：发现规则里的 JS 也要能看到真实地址
        js.host.baseUrl = parsed.url

        let content = try await fetchContent(urlString: parsed.url, options: options, page: page, keyword: "", js: js)

        let listAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        listAnalyzer.page = page
        // 发现规则缺省时回退到搜索规则，避免 bookList 为空导致整页没内容
        let exploreRule = source.exploreRule.merged(with: source.searchRule)
        let items = listAnalyzer.listItems(exploreRule.bookList)
        let books = items.compactMap { item in
            buildSearchBook(item: item, rule: exploreRule, baseUrl: parsed.url, js: js, page: page, keyword: "")
        }
        return dedupe(books)
    }

    // MARK: 详情页

    func bookInfo(bookUrl: String, bookInfo: [String: String] = [:]) async throws -> BookInfo {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: [:], title: "")

        // 有些源详情页需要 POST 或 JS 生成 URL
        var target = bookUrl
        if target.hasPrefix("@js:") || target.hasPrefix("<js>") {
            let (kind, body) = RuleSyntax.detectKind(target)
            _ = kind
            target = js.evaluateString(body)
        }

        // api 型书源：搜索结果里的详情地址为空，信息由接口/规则直接给出。
        // 这时不能拿空地址去发请求（会抛「地址为空」直接失败），
        // 只用规则本身算出 tocUrl 等字段，让调用方得以继续取目录。
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ruleJS = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: [:], title: "")
            let ruleAnalyzer = makeAnalyzer(content: nil, baseUrl: source.url, js: ruleJS)
            var info = BookInfo()
            info.name = ruleAnalyzer.string(source.bookInfoRule.name)
            info.author = ruleAnalyzer.string(source.bookInfoRule.author)
            info.kind = ruleAnalyzer.string(source.bookInfoRule.kind).nilIfBlank
            info.wordCount = ruleAnalyzer.string(source.bookInfoRule.wordCount).nilIfBlank
            info.lastChapter = ruleAnalyzer.string(source.bookInfoRule.lastChapter).nilIfBlank
            info.intro = ruleAnalyzer.string(source.bookInfoRule.intro).nilIfBlank
            let cover = ruleAnalyzer.firstString(source.bookInfoRule.coverUrl)
            info.coverUrl = RuleUtil.absoluteURL(cover, base: source.url).nilIfBlank
            let toc = ruleAnalyzer.firstString(source.bookInfoRule.tocUrl)
            info.tocUrl = toc.isEmpty ? nil : RuleUtil.absoluteURL(toc, base: source.url)
            return info
        }

        // JS 里的 baseUrl 必须是**当前详情页地址**。
        //
        // 实测：听小说APP 的目录地址规则是
        //   <js>String(baseUrl).replace('/bookinfo/','/audiolist-4/')…</js>
        // baseUrl 停在书源入口域名时 replace 不生效，算出来的目录地址
        // 少了书号，请求必然 404 —— 详情页表现就是「目录获取失败」。
        js.host.baseUrl = target

        let content = try await fetchContent(urlString: target, options: HTTPRequestOptions(), page: 1, keyword: "", js: js)
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
        let cover = detailAnalyzer.firstString(source.bookInfoRule.coverUrl)
        info.coverUrl = RuleUtil.absoluteURL(cover, base: target).nilIfBlank
        let toc = detailAnalyzer.firstString(source.bookInfoRule.tocUrl)
        info.tocUrl = toc.isEmpty ? nil : RuleUtil.absoluteURL(toc, base: target)
        return info
    }

    // MARK: 目录

    func toc(tocUrl: String, bookInfo: [String: String] = [:]) async throws -> [BookChapter] {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: [:], title: "")
        let analyzer = makeAnalyzer(content: nil, baseUrl: tocUrl, js: js)
        var target = analyzer.interpolate(tocUrl)

        // 目录规则的 JS 大量依赖全局 baseUrl 取书号 / 页号。
        //
        // 实测听小说APP 的 chapterUrl 规则：
        //   var bookId = String(baseUrl).split('/audiolist-4/')[1];
        // baseUrl 若停在书源入口域名，bookId 是空串，签名与播放地址
        // 全部算错 —— 用户看到的正是「听书源打不开」。
        js.host.baseUrl = target

        var content = try await fetchContent(urlString: target, options: HTTPRequestOptions(), page: 1, keyword: "", js: js)
        var listAnalyzer = makeAnalyzer(content: content, baseUrl: target, js: js)
        var items = listAnalyzer.listItems(source.tocRule.chapterList)

        var chapters: [BookChapter] = []
        var index = 0
        for item in items {
            let itemAnalyzer = makeAnalyzer(content: item, baseUrl: target, js: js)
            let title = itemAnalyzer.string(source.tocRule.chapterName)
            var chapterURL = itemAnalyzer.firstString(source.tocRule.chapterUrl)
            // 同上：目录项通常是 <a>，规则没给 chapterUrl 时取 href。
            if chapterURL.trimmed.isEmpty { chapterURL = elementHref(in: item) }
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
        var nextURL = listAnalyzer.firstString(source.tocRule.nextTocUrl)
        var pageCount = 0
        while !nextURL.isEmpty, pageCount < 20 {
            pageCount += 1
            let resolvedNext = RuleUtil.absoluteURL(analyzer.interpolate(nextURL), base: target)
            guard let nextContent = try? await fetchContent(urlString: resolvedNext, options: HTTPRequestOptions(), page: pageCount + 1, keyword: "", js: js) else { break }
            let nextAnalyzer = makeAnalyzer(content: nextContent, baseUrl: resolvedNext, js: js)
            let nextItems = nextAnalyzer.listItems(source.tocRule.chapterList)
            if nextItems.isEmpty { break }
            for item in nextItems {
                let itemAnalyzer = makeAnalyzer(content: item, baseUrl: resolvedNext, js: js)
                let title = itemAnalyzer.string(source.tocRule.chapterName)
                var chapterURL = itemAnalyzer.firstString(source.tocRule.chapterUrl)
                if chapterURL.trimmed.isEmpty { chapterURL = elementHref(in: item) }
                guard !title.isEmpty || !chapterURL.isEmpty else { continue }
                chapters.append(BookChapter(
                    url: RuleUtil.absoluteURL(chapterURL, base: resolvedNext),
                    title: title.isEmpty ? "第" + String(index + 1) + "章" : title,
                    index: index,
                    isVip: false, updateTime: nil, tag: nil, start: nil, end: nil, variable: nil
                ))
                index += 1
            }
            let following = nextAnalyzer.firstString(source.tocRule.nextTocUrl)
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
        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "", js: js)

        // baseUrl 对齐当前页面地址，页面匹配类脚本（baseUrl.match(...)）才正确
        js.host.baseUrl = parsed.url

        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        // 正文按段落取值：块级标签与 <br> 产生换行，阅读时排版才正常
        contentAnalyzer.paragraphs = true
        var text = contentAnalyzer.string(source.contentRule.content)

        // 图片链接（漫画 / 插图）
        // 漫画规则常直接选中 img 的容器节点，走 string() 会把 <img> 拍平成纯文本，
        // 这里改用保留 outerHTML 的 htmlString，图片才不会丢。
        let contentHTML = contentAnalyzer.htmlString(source.contentRule.content)
        var images = extractImages(from: contentHTML.isEmpty ? text : contentHTML, baseUrl: parsed.url)

        // 正文翻页
        var nextURLString = contentAnalyzer.firstString(source.contentRule.nextContentUrl)
        var pageCount = 0
        while !nextURLString.isEmpty, pageCount < 10 {
            pageCount += 1
            let nextURL = RuleUtil.absoluteURL(analyzer.interpolate(nextURLString), base: parsed.url)
            guard let nextContent = try? await fetchContent(urlString: nextURL, options: HTTPRequestOptions(), page: pageCount + 1, keyword: "", js: js) else { break }
            let nextAnalyzer = makeAnalyzer(content: nextContent, baseUrl: nextURL, js: js)
            nextAnalyzer.paragraphs = true
            let nextText = nextAnalyzer.string(source.contentRule.content)
            if nextText.isEmpty { break }
            text += "\n" + nextText
            let nextHTML = nextAnalyzer.htmlString(source.contentRule.content)
            images.append(contentsOf: extractImages(from: nextHTML.isEmpty ? nextText : nextHTML, baseUrl: nextURL))
            let following = nextAnalyzer.firstString(source.contentRule.nextContentUrl)
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

        // 漫画源兜底：正文规则取不到文字、也没解析到图片时，
        // 改成按图片规则（含 <js> 组装的链接数组）再抓一遍。
        // 原先 comicImages() 定义了却没有任何地方调用，
        // 结果就是「漫画打不开 / 本章没有图片」。
        if images.isEmpty, text.count < 200 {
            let comicAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
            // 有些源把图片规则写在 content 里，另一些单独写在 imageStyle
            let ruleCandidates = [source.contentRule.content, source.contentRule.imageStyle]
            for rule in ruleCandidates {
                guard let rule, !rule.trimmed.isEmpty else { continue }
                let html = comicAnalyzer.htmlString(rule)
                let found = extractImages(from: html.isEmpty ? content : html, baseUrl: parsed.url)
                if !found.isEmpty {
                    images = dedupeImages(found)
                    break
                }
            }
        }

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
        audioLock.lock()
        if let cached = audioCache[chapterUrl], !cached.isEmpty {
            audioLock.unlock()
            return cached
        }
        audioLock.unlock()

        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: chapterInfo, title: chapterTitle)
        let analyzer = makeAnalyzer(content: nil, baseUrl: chapterUrl, js: js)
        var target = analyzer.interpolate(chapterUrl)
        if target.hasPrefix("@js:") {
            target = js.evaluateString(String(target.dropFirst(4)))
        }

        let parsed = HTTPClient.parseURLRule(target)

        // 目录规则有时直接给出音频直链（喜马拉雅就写
        // `playPathAacv224||playPathAacv164||playUrl64||playUrl32`，
        // 解析出来就是音频文件地址）。这种地址必须原样返回。
        //
        // 旧实现无条件去请求它：把几十 MB 的音频当 HTML 下载，
        // 再从中「提取音频链接」—— 必然一无所获。
        // 这正是听书源一律打不开的直接原因。
        if Self.isDirectMediaURL(parsed.url, extensions: Self.audioExtensions) {
            audioLock.lock()
            audioCache[chapterUrl] = parsed.url
            audioLock.unlock()
            return parsed.url
        }

        // 扩展名没命中时再问一次 Content-Type。
        //
        // 站点的媒体字段常常不带扩展名（例如喜马拉雅的 playPath 值形如
        // `https://aod.../xxx?auth=...`），只按扩展名判断会漏掉；
        // 漏掉就会去下载几十 MB 的音频当 HTML 解析，必然失败。
        if await isMediaResponse(urlString: parsed.url, options: parsed.options) {
            audioLock.lock()
            audioCache[chapterUrl] = parsed.url
            audioLock.unlock()
            return parsed.url
        }

        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "", js: js)
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
        audioLock.lock()
        audioCache[chapterUrl] = first
        audioLock.unlock()
        return first
    }

    /// 影视 / 短剧：取出当前章节对应的视频直链。
    ///
    /// 结构与 audioURL 一致，只是扩展名集合不同：
    /// 站点常见三种给法 ——
    /// 1. 正文规则直接返回 m3u8 / mp4；
    /// 2. 返回一段播放器代码（player_aaaa、data-ep-src 等），需要扫出链接；
    /// 3. 只给一次解析结果，因此缓存复用。
    ///
    /// 与音频分开缓存：同一本书可能同时有音视频源，键相同会串台。
    func videoURL(
        chapterUrl: String,
        bookInfo: [String: String] = [:],
        chapterInfo: [String: String] = [:],
        chapterTitle: String = ""
    ) async throws -> String {
        videoLock.lock()
        if let cached = videoCache[chapterUrl], !cached.isEmpty {
            videoLock.unlock()
            return cached
        }
        videoLock.unlock()

        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: chapterInfo, title: chapterTitle)
        let analyzer = makeAnalyzer(content: nil, baseUrl: chapterUrl, js: js)
        var target = analyzer.interpolate(chapterUrl)
        if target.hasPrefix("@js:") {
            target = js.evaluateString(String(target.dropFirst(4)))
        }

        let parsed = HTTPClient.parseURLRule(target)

        // 同 audioURL：目录规则直接给出 m3u8 / mp4 时不能再去抓它，
        // 否则会把视频文件当 HTML 下载，再从中「提取视频链接」。
        if Self.isDirectMediaURL(parsed.url, extensions: Self.videoExtensions) {
            videoLock.lock()
            videoCache[chapterUrl] = parsed.url
            videoLock.unlock()
            return parsed.url
        }

        // 同 audioURL：扩展名没命中时问一次 Content-Type
        if await isMediaResponse(urlString: parsed.url, options: parsed.options) {
            videoLock.lock()
            videoCache[chapterUrl] = parsed.url
            videoLock.unlock()
            return parsed.url
        }

        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "", js: js)
        js.host.baseUrl = parsed.url
        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)

        var candidates: [String] = []

        // 正文规则的结果本身就是地址（短剧源最常见的写法）
        let direct = contentAnalyzer.string(source.contentRule.content)
        candidates.append(contentsOf: RuleUtil.extractURLs(direct).filter { Self.isVideoURL($0) })
        candidates.append(contentsOf: videoLinks(in: direct, baseUrl: parsed.url))

        // 规则没命中时，退回整页扫描
        if candidates.isEmpty {
            candidates.append(contentsOf: videoLinks(in: content, baseUrl: parsed.url))
        }

        // 兜底：JSON 形式返回的字段
        if candidates.isEmpty {
            for key in ["url", "src", "video", "playUrl", "play_url", "m3u8", "dplayer"] {
                let value = contentAnalyzer.string("$." + key)
                guard !value.isEmpty else { continue }
                candidates.append(contentsOf: videoLinks(in: value, baseUrl: parsed.url))
            }
        }

        guard let first = candidates.first(where: { !$0.isEmpty }) else {
            throw SourceError.emptyContent
        }
        videoLock.lock()
        videoCache[chapterUrl] = first
        videoLock.unlock()
        return first
    }

    /// 地址是否像视频（含 HLS 的 m3u8）。
    static func isVideoURL(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for ext in videoExtensions.split(separator: "|") {
            if lowered.contains(".\(ext)") { return true }
        }
        return false
    }

    /// 地址本身是否就是媒体文件（按扩展名判定）。
    ///
    /// 不能用 `isVideoURL` 那种 `contains(".mp3")` 来判断能不能直接交给播放器：
    /// `https://a.com/page?id=1.mp3` 明显是个网页，却也「包含 .mp3」。
    /// 判错的后果是把网页当音频播出去，用户只会看到一直转圈。
    ///
    /// 规则：
    /// - 必须是绝对地址（相对路径交给播放器无法解析，仍需按章节页拼接）；
    /// - 去掉 query / fragment 后，路径必须以媒体扩展名结尾。
    static func isDirectMediaURL(_ value: String, extensions: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("//") else { return false }

        var path = trimmed
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<cut])
        }
        let pathLowered = path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for ext in extensions.split(separator: "|") {
            if pathLowered.hasSuffix("." + ext) { return true }
        }
        return false
    }

    /// 用 HEAD 探一次 Content-Type，判断这个地址是不是媒体文件。
    ///
    /// 只发 HEAD 不发 GET：地址是媒体时体积可能几十 MB，
    /// 为了「判断类型」先下载一遍完全不可接受。
    ///
    /// 探不到结论（站点不支持 HEAD / 超时 / 网络错误）时一律返回 false，
    /// 交给上层原有的解析流程 —— 这里只是多一次廉价的机会，
    /// 不允许因为探测失败而把原本能解析的源弄坏。
    private func isMediaResponse(urlString: String, options: HTTPRequestOptions) async -> Bool {
        guard !urlString.isEmpty else { return false }
        var probe = options
        probe.method = "HEAD"
        probe.body = nil
        // 探测必须快：卡在慢站点上会把「打开章节」拖成几十秒
        probe.timeout = 8
        do {
            let response = try await HTTPClient.shared.request(
                urlString: urlString,
                options: probe,
                sourceKey: source.cookieJar ? source.id : nil,
                defaultHeaders: headers,
                base: baseForResolving(urlString, fallback: source.url)
            )
            return Self.isMediaContentType(response.header("Content-Type"))
        } catch {
            return false
        }
    }

    /// Content-Type 是否指向音频 / 视频流。
    static func isMediaContentType(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let lowered = value.lowercased()
        return lowered.hasPrefix("audio/")
            || lowered.hasPrefix("video/")
            // HLS 播放列表：Swift 的 AVPlayer 可直接播
            || lowered.contains("mpegurl")
            || lowered.contains("m3u")
    }

    /// 从文本中匹配常见音频链接
    private func audioLinks(in value: String, baseUrl: String) -> [String] {
        mediaLinks(in: value, baseUrl: baseUrl, extensions: Self.audioExtensions)
    }

    /// 从文本中匹配常见视频链接
    ///
    /// 短剧 / 影视源（bookSourceType = 4）的正文规则普遍直接吐一个
    /// m3u8 或 mp4 地址，也有把地址塞在 player_aaaa / data-src 里的写法，
    /// 因此和音频一样按扩展名扫全文，而不依赖某一种固定字段。
    private func videoLinks(in value: String, baseUrl: String) -> [String] {
        mediaLinks(in: value, baseUrl: baseUrl, extensions: Self.videoExtensions)
    }

    private static let audioExtensions = "mp3|m4a|aac|ogg|flac|wav|ape|wma|m3u8"
    /// m3u8 同时出现在两种列表里：HLS 既用于音频也用于视频，
    /// 谁先匹配到取决于调用方传的扩展名集合。
    private static let videoExtensions = "mp4|m3u8|flv|mkv|avi|mov|wmv|webm|ts|rmvb|m4v"

    /// 按扩展名从任意文本里捞出媒体直链。
    ///
    /// 排除 `,` 与 `;`：JSON 里地址后常紧跟分隔符，
    /// 把它们吞进地址会拼出 404 的链接。
    private func mediaLinks(in value: String, baseUrl: String, extensions: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let pattern = "(?:https?:)?//[^\\s\"'<>\\,;]+?\\.(?:" + extensions + ")(?:\\?[^\\s\"'<>\\,;]*)?"
        let matched = RuleUtil.regexMatch(value, pattern: pattern)
        // 去重但保持出现顺序：同一地址在页面里往往被引用多次
        var seen = Set<String>()
        return matched
            .map { RuleUtil.absoluteURL($0, base: baseUrl) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 漫画：把章节内所有图片按顺序取出
    func comicImages(chapterUrl: String, bookInfo: [String: String] = [:], chapterInfo: [String: String] = [:]) async throws -> [String] {
        let js = makeJSEngine(content: nil, bookInfo: bookInfo, chapterInfo: chapterInfo, title: "")
        let analyzer = makeAnalyzer(content: nil, baseUrl: chapterUrl, js: js)
        let target = analyzer.interpolate(chapterUrl)
        let parsed = HTTPClient.parseURLRule(target)

        let content = try await fetchContent(urlString: parsed.url, options: parsed.options, page: 1, keyword: "", js: js)
        js.host.baseUrl = parsed.url
        let contentAnalyzer = makeAnalyzer(content: content, baseUrl: parsed.url, js: js)
        var value = contentAnalyzer.string(source.contentRule.content)
        if value.isEmpty { value = content }

        var images = extractImages(from: value, baseUrl: parsed.url)

        // 翻页
        var nextURLString = contentAnalyzer.firstString(source.contentRule.nextContentUrl)
        var pageCount = 0
        while !nextURLString.isEmpty, pageCount < 10 {
            pageCount += 1
            let nextURL = RuleUtil.absoluteURL(analyzer.interpolate(nextURLString), base: parsed.url)
            guard let nextContent = try? await fetchContent(urlString: nextURL, options: HTTPRequestOptions(), page: pageCount + 1, keyword: "", js: js) else { break }
            let nextAnalyzer = makeAnalyzer(content: nextContent, baseUrl: nextURL, js: js)
            let nextValue = nextAnalyzer.string(source.contentRule.content)
            images.append(contentsOf: extractImages(from: nextValue.isEmpty ? nextContent : nextValue, baseUrl: nextURL))
            let following = nextAnalyzer.firstString(source.contentRule.nextContentUrl)
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
        keyword: String,
        js incomingJS: JSEngine? = nil
    ) async throws -> String {
        guard !urlString.isEmpty else { throw SourceError.emptyURL }
        // 复用调用方已经建好的引擎：原先每翻一页都新建一个 JSVirtualMachine，
        // 漫画翻几十页就会堆出几十个虚拟机，内存被顶爆后闪退。
        let js = incomingJS ?? makePlumbingJS()
        js.page = page
        js.key = keyword

        var options = incomingOptions
        var target = urlString

        // URL 内的 js 改写：url,{"js":"..."}
        //
        // 旧实现死认 `,{"js"` 这个带引号的字面量，源里写成 `,{js:"..."}`
        // （键名不带引号）就整段识别不到，于是地址里残留 `,{...}`，
        // 请求必然失败。这里改用与 parseURLRule 同一套宽容解析。
        if let split = HTTPClient.splitTrailingOptions(urlString),
           let dictionary = HTTPClient.optionObject(from: split.options),
           let script = dictionary.str("js") {
            target = split.url
            for (key, value) in dictionary { options.headers[key] = RuleUtil.asString(value) ?? "" }
            js.host.baseUrl = target
            _ = js.evaluate(script)
            if let mutated = js.host.baseUrl.nilIfBlank { target = mutated }
        }

        let analyzer = makeAnalyzer(content: nil, baseUrl: target, js: js)
        analyzer.page = page
        analyzer.key = keyword
        target = analyzer.interpolate(target)

        // 正文页往往比列表页慢（站点要做权限/解锁处理），
        // 15 秒的搜索时限太紧，这里放宽到 30 秒并在超时后重试一次。
        options.timeout = max(options.timeout, 30)
        var response: HTTPResponse
        do {
            response = try await HTTPClient.shared.request(
                urlString: target,
                options: options,
                sourceKey: source.cookieJar ? source.id : nil,
                defaultHeaders: headers,
                base: baseForResolving(target, fallback: source.url)
            )
        } catch let error as URLError where error.code == .timedOut {
            response = try await HTTPClient.shared.request(
                urlString: target,
                options: options,
                sourceKey: source.cookieJar ? source.id : nil,
                defaultHeaders: headers,
                base: baseForResolving(target, fallback: source.url)
            )
        }

        // 登录检查
        if let check = source.loginCheckJs.nilIfBlank {
            js.host.document = HTMLParser.parse(response.text)
            js.src = response.text
            // 登录检查脚本的 result 是响应对象（对齐 Legado 的
            // evalJS(loginCheckJs, strResponse)）。脚本据此调
            // result.body() / result.code() / result.url() 判断限频与验证页。
            // 不注入时这些调用全是 "null is not an object"，
            // 该弹出的验证窗口永远不弹。
            js.lastResponse = response
            _ = js.evaluateLoginCheck(check, response: response)
        }
        return response.text
    }

    private func performRequest(
        urlString: String,
        options: HTTPRequestOptions,
        page: Int,
        keyword: String,
        js incomingJS: JSEngine? = nil
    ) async throws -> HTTPResponse {
        guard !urlString.isEmpty else { throw SourceError.emptyURL }
        let js = incomingJS ?? makePlumbingJS()
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

        // 记住最后一次响应：java.getResponse() / java.redirectUrl /
        // java.getHeaderMap() 都要读它（11 个源 + 57 处）。
        js.lastResponse = response

        if let check = source.loginCheckJs.nilIfBlank {
            js.host.document = HTMLParser.parse(response.text)
            js.src = response.text
            _ = js.evaluateLoginCheck(check, response: response)
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
        // 书源元信息：脚本用 source.bookSourceComment 解 helper、
        // 用 source.getKey()/source.bookSourceUrl 拼请求地址，
        // 用 source.loginUrl 走登录流程。
        host.sourceUrl = source.url
        host.sourceComment = source.bookSourceComment
        host.variableComment = source.variableComment
        host.sourceHeader = source.header
        host.loginUrl = source.loginUrl
        host.concurrentRate = source.concurrentRate
        host.baseUrl = source.url
        host.headers = headers
        host.bookInfo = bookInfo
        host.chapterInfo = chapterInfo
        host.title = title
        host.variables = variables
        host.document = content as? HTMLNode

        // 书籍级上下文：书源据此判断进度与目录规模
        let context = bookContext
        host.bookUrl = context.url.isEmpty ? (bookInfo["bookUrl"] ?? "") : context.url
        host.bookType = context.type
        host.totalChapterNum = context.totalChapterNum
        host.canUpdate = context.canUpdate
        host.customIntro = context.customIntro
        host.latestChapterTitle = context.latestChapterTitle
        host.bookStatus = context.status
        host.reverseToc = context.reverseToc
        // 进度字段：调用方传进来的 chapterInfo 优先（求某一章时就是那一章），
        // 否则用书架的「上次读到哪儿」。
        if let raw = chapterInfo["index"], let value = Int(raw) {
            host.durChapterIndex = value
        } else {
            host.durChapterIndex = context.durChapterIndex
        }
        host.durChapterTitle = chapterInfo["title"] ?? context.durChapterTitle

        // 书源声明原样透传给脚本。
        //
        // 源里写 `source.bookSourceType == '3'` / `String(source.exploreUrl).match(…)`
        // 这类**按原文比较**的判断，归一化后的 typed 值对不上。
        // 解析失败（旧数据没有这一列）时留空字典，行为与改动前一致。
        if let metaJSON = source.metaJSON, !metaJSON.isEmpty,
           let data = metaJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            host.sourceMeta = parsed
        }
        host.bookOrder = context.order

        let js = JSEngine(host: host)
        js.src = (content as? String) ?? ""

        // 书源级变量注入 + 回写。
        //
        // 表单型发现源把用户的选择存在 source.getVariable() 里
        // （七猫 / 奈飞工厂 / 听小说APP 的「切换频道」都是这个套路），
        // 而引擎每次求值都会新建 JSEngine —— 不注入就等于每次刷新都重置，
        // 用户点了频道切换却发现列表没变。
        js.sourceVariable = SourceVariableStore.shared[source.id] ?? ""
        // 变量注入后才能建出「带上次选择」的 infoMap
        js.reloadInfoMap()

        // 求值结束后回写：脚本里 source.setVariable(...) 的结果必须落盘，
        // 否则「切换频道」这类选择在下次刷新时又回到默认值。
        js.onVariableChanged = { [weak self] value in
            guard let self else { return }
            SourceVariableStore.shared[self.source.id] = value
        }

        // 表单按钮：搜索 / 刷新发现 / 提示
        js.onSearchBook = { [weak self] keyword in self?.onSearchBook?(keyword) }
        js.onRefreshExplore = { [weak self] in self?.onRefreshExplore?() }
        js.onToast = { [weak self] text in self?.onToast?(text) }

        // 兼容层新增的宿主钩子。
        //
        // 这些 API（refreshTocUrl / upLoginData / openVideoPlayer / …）
        // 光「注册成不报错的空实现」只解决「脚本不中断」，
        // 真正的语义（刷新目录、保存登录信息、播放视频）必须落到宿主，
        // 否则用户看到的是「点了没反应」。
        js.onRefreshRequest = { [weak self] name in
            guard let self else { return }
            // 先登记，避免在 JS 求值内部重入网络请求；
            // 调用方在本次操作结束后用 consumePendingRefresh() 取走执行。
            self.markPendingRefresh(name)
            self.onRefreshRequest?(name)
        }
        js.onLoginInfoChanged = { [weak self] info in
            guard let self, !info.isEmpty else { return }
            self.sourceLoginInfo = info
            self.onLoginInfoChanged?(info)
        }
        js.onRequestLogin = { [weak self] in
            self?.onRequestLogin?()
        }
        js.onOpenVideo = { [weak self] url, title in
            self?.onOpenVideo?(url, title)
        }
        js.host.onAddBook = { [weak self] url in
            self?.onAddBook?(url)
        }
        js.host.onClipboard = { [weak self] text in
            self?.onClipboard?(text)
        }
        js.host.onReverseTocChanged = { [weak self] flag in
            self?.onReverseTocChanged?(flag)
        }
        js.host.onBookTypeChanged = { [weak self] type in
            self?.onBookTypeChanged?(type)
        }

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

        // 书源可用 java.startBrowserAwait 弹出验证窗口：
        // 这里提供「在后台线程阻塞等待、界面在主线程弹出」的桥接。
        js.awaitUserAction = { [weak js] url, title in
            let key = js?.host.sourceKey ?? ""
            let semaphore = DispatchSemaphore(value: 0)
            let box = ValueBox<String>("")
            DispatchQueue.main.async {
                WebAuthPresenter.shared.present(url: url, title: title, sourceKey: key) { cookie in
                    box.set(cookie)
                    semaphore.signal()
                }
            }
            // 超时上限：用户长时间不操作时不要让脚本永久挂起
            if semaphore.wait(timeout: .now() + 600) == .timedOut {
                DispatchQueue.main.async { WebAuthPresenter.shared.cancel() }
                return ""
            }
            return box.current
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
        var bookURL = analyzer.firstString(rule.bookUrl)
        // 书源没写 bookUrl（只写了 bookList + name）时，Legado 会退回取元素自身的
        // href；yckceo 上一大批源都是这种写法，不回退就会得到空地址。
        if bookURL.trimmed.isEmpty { bookURL = elementHref(in: item) }
        guard !name.isEmpty || !bookURL.isEmpty else { return nil }

        let author = analyzer.string(rule.author)
        let cover = analyzer.firstString(rule.coverUrl)

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

    /// 取列表条目自身指向的地址。
    ///
    /// 对齐 Legado 的默认行为：书源只写了列表规则、没写 bookUrl /
    /// chapterUrl 时，直接使用条目元素的 href（JSON 条目则取 url / link）。
    /// 没有这一步，yckceo 上一大批「只给列表+书名」的源会拿到空地址。
    private func elementHref(in item: Any) -> String {
        if let node = item as? HTMLNode {
            let value = node.attribute("href") ?? node.attribute("data-href") ?? ""
            if !value.trimmed.isEmpty { return value }
            // <a> 之外常见写法：把地址放在子元素或 data-src 上
            for key in ["data-url", "data-src", "data-original"] {
                if let found = node.attribute(key), !found.trimmed.isEmpty { return found }
            }
            return ""
        }
        if let dictionary = item as? [String: Any] {
            for key in ["bookUrl", "url", "link", "href", "detailUrl"] {
                if let value = RuleUtil.asString(dictionary[key]), !value.trimmed.isEmpty { return value }
            }
        }
        if let text = item as? String { return text.trimmed }
        return ""
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
            // 地址为空时不能用 book.id 当键：所有空地址的书会算成同一条，
            // 整个书源的结果会被压成一本。这时退化成「书名+作者」当键。
            let key = book.bookUrl.trimmed.isEmpty
                ? "name:" + book.name + "|" + book.author
                : book.id
            guard seen.insert(key).inserted else { continue }
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

    /// 去掉正文里的 HTML 残留。
    ///
    /// 大量书源的正文规则是 @js 脚本，直接返回 innerHTML 字符串，
    /// 这些标签会原样显示成「<br/><br/>」「<script>read2();</script>」，
    /// 阅读时又乱又没法看。这里把块级标签与 <br> 还原成换行，
    /// 其余标签剥掉，最后解码 HTML 实体。
    static func stripHTMLArtifacts(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") else { return text }
        var value = text

        // script / style 整块丢弃（先处理成对出现的）
        value = RuleUtil.regexReplace(value, pattern: "(?i)<script[^>]*>.*?</script\\s*>", replacement: "")
        value = RuleUtil.regexReplace(value, pattern: "(?i)<style[^>]*>.*?</style\\s*>", replacement: "")
        // 未闭合的 script / style：只吃到行尾，避免把整篇正文一起吞掉
        value = RuleUtil.regexReplace(value, pattern: "(?i)<script[^>]*>[^\\n]*", replacement: "")
        value = RuleUtil.regexReplace(value, pattern: "(?i)<style[^>]*>[^\\n]*", replacement: "")
        // 注释与 doctype
        value = RuleUtil.regexReplace(value, pattern: "(?i)<!--.*?-->", replacement: "")
        value = RuleUtil.regexReplace(value, pattern: "(?i)<!doctype[^>]*>", replacement: "")
        // 块级边界还原成换行，段落才不会粘成一行
        value = RuleUtil.regexReplace(value, pattern: "(?i)<\\s*br\\s*/?\\s*>", replacement: "\n")
        value = RuleUtil.regexReplace(
            value,
            pattern: "(?i)</?\\s*(p|div|li|h[1-6]|tr|section|article|blockquote|dd|dt|ul|ol|table|figure|pre)\\b[^>]*>",
            replacement: "\n"
        )
        // 剩下所有标签剥掉
        value = RuleUtil.regexReplace(value, pattern: "(?i)<[^>]+>", replacement: "")
        // 实体还原（&nbsp; &amp; &#39; 等）
        value = HTMLParser.decodeEntities(value)
        return value
    }

    func cleanContent(_ text: String) -> String {
        // 先把 HTML 残留清掉：正文规则返回 innerHTML 时标签会直接进正文
        var result = SourceEngine.stripHTMLArtifacts(text)

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
    /// 发现规则缺省时回退到搜索规则。
    ///
    /// yckceo 上一批源只写了 exploreUrl，列表规则直接复用 ruleSearch。
    /// 原先发现页只读 ruleExplore，bookList 为空就一条都取不到，
    /// 表现就是「发现页下面没东西 / 该分类暂无内容」。
    func merged(with fallback: SearchRule) -> SearchRule {
        var rule = asSearchRule
        if rule.bookList?.trimmed.isEmpty ?? true { rule.bookList = fallback.bookList }
        if rule.name?.trimmed.isEmpty ?? true { rule.name = fallback.name }
        if rule.author?.trimmed.isEmpty ?? true { rule.author = fallback.author }
        if rule.kind?.trimmed.isEmpty ?? true { rule.kind = fallback.kind }
        if rule.wordCount?.trimmed.isEmpty ?? true { rule.wordCount = fallback.wordCount }
        if rule.lastChapter?.trimmed.isEmpty ?? true { rule.lastChapter = fallback.lastChapter }
        if rule.intro?.trimmed.isEmpty ?? true { rule.intro = fallback.intro }
        if rule.coverUrl?.trimmed.isEmpty ?? true { rule.coverUrl = fallback.coverUrl }
        if rule.bookUrl?.trimmed.isEmpty ?? true { rule.bookUrl = fallback.bookUrl }
        return rule
    }

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
