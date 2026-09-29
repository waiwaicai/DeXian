import Foundation
import Combine

/// 阅读状态：目录加载、章节切换、正文缓存
@MainActor
final class ReaderViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var content: String = ""
    @Published private(set) var images: [String] = []
    /// 音频书源解析出的直链（听书用）
    @Published private(set) var audioUrl: String = ""
    /// 视频书源（影视 / 短剧）解析出的直链
    @Published private(set) var videoUrl: String = ""
    /// 播放器是否处于全屏。
    ///
    /// 由播放器写入、阅读页读取：全屏时要让外层顶 / 底浮层让位，
    /// 两个视图共享同一份状态，避免各自维护后不同步。
    @Published var isVideoFullScreen = false
    @Published var currentIndex: Int = 0
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingContent = false
    /// 整本离线缓存进度
    @Published private(set) var cacheProgress = ChapterCache.Progress()
    /// 本地已缓存章节数（用于界面提示）
    @Published private(set) var cachedChapterCount = 0

    let book: ShelfBook
    /// 书源缺失时为 nil，界面会提示换源
    private let engine: SourceEngine?
    private let shelf: ShelfStore
    /// 正文内存缓存。
    ///
    /// 每章正文几千到几万字，翻几百章就会累积到几十 MB。
    /// 这里限制条数，超出后按插入顺序淘汰最早的章节（保留当前几章）。
    private var contentCache: [String: ChapterContent] = [:]
    private var contentCacheOrder: [String] = []
    private let contentCacheLimit = 12
    private var loadTask: Task<Void, Never>?
    /// 视频直链解析进行中标记，防止并发重复请求
    private var isResolvingVideo = false
    private var cacheObserver: AnyCancellable?

    init(book: ShelfBook, source: BookSource?, shelf: ShelfStore) {
        self.book = book
        self.shelf = shelf
        engine = source.map { SourceEngine(source: $0, variables: book.variable) }
        chapters = book.chapters
        currentIndex = book.lastReadChapterIndex
        cachedChapterCount = ChapterCache.shared.counts(bookId: book.id).cached
        // meta 读取放后台：原先 init 里同步读 meta.json，
        // 书架每本书都会各读一次，书多时启动路径又变成一串主线程 IO
        Task { [weak self] in
            await ChapterCache.shared.loadMeta(bookId: book.id)
            guard let self else { return }
            self.cachedChapterCount = ChapterCache.shared.counts(bookId: self.book.id).cached
        }
        // 缓存由单例驱动，进度变化时同步到界面
        cacheObserver = ChapterCache.shared.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.cacheProgress = value
                self.cachedChapterCount = ChapterCache.shared.counts(bookId: self.book.id).cached
            }
    }

    var hasSource: Bool { engine != nil }

    var currentChapter: BookChapter? {
        guard chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    var progressText: String {
        guard !chapters.isEmpty else { return "" }
        return String(currentIndex + 1) + "/" + String(chapters.count)
    }

    var progress: Double {
        guard chapters.count > 1 else { return 1 }
        return Double(currentIndex) / Double(chapters.count - 1)
    }

    /// 是否音频（听书）书源
    var isAudio: Bool { book.type == .audio }

    /// 是否影视 / 短剧书源
    var isVideo: Bool { book.type == .video }

    /// 是否漫画模式
    var isComic: Bool {
        book.type == .image || (book.type == .text && !images.isEmpty && content.isEmpty)
    }

    // MARK: 目录

    func loadTocIfNeeded() async {
        if !chapters.isEmpty { return }
        // 地址为空的记录：多半是书源没写 bookUrl 又没能回退到 href，
        // 这种情况继续请求只会得到一句「地址为空」，干脆直接告诉用户换源。
        guard !book.bookUrl.trimmed.isEmpty || !(book.tocUrl ?? "").trimmed.isEmpty else {
            state = .failed("这本书没有可用地址，请在搜索页换一个书源")
            return
        }
        guard let engine else {
            state = .failed("书源缺失，请重新添加书籍")
            return
        }
        state = .loading
        do {
            let list = try await engine.toc(tocUrl: tocUrlForLoading, bookInfo: bookInfoMap)
            chapters = list
            state = .loaded
            shelf.updateChapters(bookId: book.id, chapters: list)
            shelf.updateVariables(bookId: book.id, variables: engine.variableSnapshot)
        } catch {
            // 漫画源普遍不提供章节目录：整本就是一个阅读页。
            // 这类书源在详情页会一直是「目录获取失败」，用户根本进不去。
            // 这里退一步，直接拿书籍页当成唯一一章去解析图片，
            // 把「打不开」变成「能看」。
            if await fallbackToSingleChapter() { return }
            state = .failed(SourceError.describe(error))
        }
    }

    /// 漫画源兜底：没有目录时把书籍页本身当作唯一一章。
    ///
    /// 返回 true 表示已成功建立可读的单章，调用方不应再报错。
    private func fallbackToSingleChapter() async -> Bool {
        // 影视源多数只有单集页面：目录失败就直接把书籍页当唯一一集。
        // 这里不预取直链 —— 播放器拿到章节后会调 loadVideo()，
        // 预取一次等于同一个页面被请求两遍。
        if book.type == .video {
            let candidate = (book.tocUrl ?? "").trimmed.isEmpty ? book.bookUrl : (book.tocUrl ?? "")
            let target = candidate.trimmed
            guard !target.isEmpty else { return false }
            let chapter = BookChapter(url: target, title: book.name, index: 0,
                                      isVip: false, updateTime: nil, tag: nil,
                                      start: nil, end: nil, variable: nil)
            chapters = [chapter]
            currentIndex = 0
            state = .loaded
            shelf.updateChapters(bookId: book.id, chapters: chapters)
            return true
        }

        // 漫画源整本一个阅读页：拿书籍页当唯一一章并立刻解析图片。
        guard book.type == .image else { return false }
        // 不要用 book.tocUrl! —— 这里是网络失败路径，
        // 在这种地方强制解包等于把「加载失败」升级成「闪退」。
        let tocCandidate = (book.tocUrl ?? "").trimmed
        let target = tocCandidate.isEmpty ? book.bookUrl : tocCandidate
        guard !target.trimmed.isEmpty, let engine else { return false }
        do {
            let result = try await engine.content(
                chapterUrl: target,
                bookInfo: bookInfoMap,
                chapterInfo: ["title": book.name, "url": target, "index": "0", "bookUrl": book.bookUrl],
                chapterTitle: book.name
            )
            guard !result.images.isEmpty else { return false }
            let chapter = BookChapter(url: target, title: book.name, index: 0,
                                      isVip: false, updateTime: nil, tag: nil,
                                      start: nil, end: nil, variable: nil)
            chapters = [chapter]
            currentIndex = 0
            content = result.text
            images = result.images
            state = .loaded
            shelf.updateChapters(bookId: book.id, chapters: chapters)
            return true
        } catch {
            return false
        }
    }

    func reloadToc() async {
        chapters = []
        content = ""
        images = []
        audioUrl = ""
        videoUrl = ""
        await loadTocIfNeeded()
    }

    private var tocUrlForLoading: String {
        book.tocUrl ?? book.bookUrl
    }

    private var bookInfoMap: [String: String] {
        [
            "name": book.name,
            "author": book.author,
            "bookUrl": book.bookUrl,
            "tocUrl": book.tocUrl ?? "",
            "origin": book.origin,
            "originName": book.originName,
            "coverUrl": book.coverUrl ?? "",
            "intro": book.intro ?? "",
            "kind": book.kind ?? ""
        ]
    }

    // MARK: 内容

    func loadContent(index: Int) async {
        guard chapters.indices.contains(index) else { return }
        currentIndex = index

        // 音频书源没有正文，改为解析音频直链
        if book.type == .audio {
            await loadAudio()
            return
        }

        // 影视 / 短剧书源同样没有正文，改为解析视频直链
        if book.type == .video {
            await loadVideo()
            return
        }

        let chapter = chapters[index]

        // 先取消上一次还在跑的抓取。
        // 原先只在「真正要联网」的分支里取消，于是快速翻章时，
        // 旧任务仍会在稍后写回 content，把当前章覆盖成上一章的内容。
        loadTask?.cancel()
        loadTask = nil

        if let cached = contentCache[chapter.url] {
            touchCache(chapter.url)
            content = cached.text
            images = cached.images
            state = .loaded
            isLoadingContent = false
            return
        }

        // 离线缓存优先：断网也能读（磁盘读取在后台线程）
        if let offline = await ChapterCache.shared.content(bookId: book.id, chapterUrl: chapter.url) {
            storeCache(chapter.url, offline)
            content = offline.text
            images = offline.images
            state = .loaded
            isLoadingContent = false
            return
        }

        await ChapterCache.shared.loadMeta(bookId: book.id)

        isLoadingContent = true
        content = ""
        images = []

        let info = bookInfoMap
        let chapterInfo: [String: String] = [
            "title": chapter.title,
            "url": chapter.url,
            "index": String(chapter.index),
            "baseUrl": chapter.url,
            "bookUrl": book.bookUrl
        ]

        guard let engine else {
            state = .failed("书源缺失，请重新添加书籍")
            isLoadingContent = false
            return
        }
        // 先恢复上次保存的变量，再抓取正文
        for (key, value) in book.variable { engine.variables[key] = value }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.content(
                    chapterUrl: chapter.url,
                    bookInfo: info,
                    chapterInfo: chapterInfo,
                    chapterTitle: chapter.title
                )
                // 已被取消，或用户已经翻到别的章节：
                // 直接丢弃结果，绝不能写回（否则会把当前章覆盖成上一章内容）。
                guard !Task.isCancelled, self.currentChapter?.url == chapter.url else {
                    // 只有「自己仍是当前章」时才需要复位加载态；
                    // 否则会把新一章正在转的加载指示器误关掉。
                    if self.currentChapter?.url == chapter.url { self.isLoadingContent = false }
                    return
                }
                self.storeCache(chapter.url, result)
                self.content = result.text
                self.images = result.images
                self.state = .loaded
                await ChapterCache.shared.store(
                    bookId: self.book.id,
                    name: self.book.name,
                    origin: self.book.origin,
                    chapterUrl: chapter.url,
                    content: result
                )
                self.isLoadingContent = false
                self.shelf.updateVariables(bookId: self.book.id, variables: engine.variableSnapshot)
                self.shelf.updateProgress(
                    bookId: self.book.id,
                    chapterIndex: index,
                    chapterTitle: chapter.title,
                    offset: 0
                )
            } catch {
                // 同上：过期的失败不能覆盖当前章节的状态
                guard !Task.isCancelled, self.currentChapter?.url == chapter.url else { return }
                self.state = .failed(SourceError.describe(error))
                self.isLoadingContent = false
            }
        }
    }

    /// 听书：解析当前章节的音频直链
    func loadAudio() async {
        guard let engine, let chapter = currentChapter else { return }
        for (key, value) in book.variable { engine.variables[key] = value }
        isLoadingContent = true
        // 先清空，避免加载途中误播上一章的音频
        audioUrl = ""
        do {
            let url = try await engine.audioURL(
                chapterUrl: chapter.url,
                bookInfo: bookInfoMap,
                chapterInfo: [
                    "title": chapter.title,
                    "url": chapter.url,
                    "index": String(chapter.index),
                    "bookUrl": book.bookUrl
                ],
                chapterTitle: chapter.title
            )
            audioUrl = url
            state = .loaded
            shelf.updateVariables(bookId: book.id, variables: engine.variableSnapshot)
            shelf.updateProgress(
                bookId: book.id,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                offset: 0
            )
        } catch {
            audioUrl = ""
            state = .failed(SourceError.describe(error))
        }
        isLoadingContent = false
    }

    /// 影视 / 短剧：解析当前章节的视频直链
    func loadVideo() async {
        // 去重：进入播放页时，阅读页的 .task 与播放器自己的 .task
        // 会同时触发一次解析；引擎缓存要等首轮结束才写得上，
        // 并发两轮就是同一个页面被请求两次。
        guard !isResolvingVideo else { return }
        isResolvingVideo = true
        defer { isResolvingVideo = false }

        guard let engine, let chapter = currentChapter else { return }
        for (key, value) in book.variable { engine.variables[key] = value }
        isLoadingContent = true
        // 先清空，避免加载途中误播上一集
        videoUrl = ""
        do {
            let url = try await engine.videoURL(
                chapterUrl: chapter.url,
                bookInfo: bookInfoMap,
                chapterInfo: [
                    "title": chapter.title,
                    "url": chapter.url,
                    "index": String(chapter.index),
                    "bookUrl": book.bookUrl
                ],
                chapterTitle: chapter.title
            )
            videoUrl = url
            state = .loaded
            shelf.updateVariables(bookId: book.id, variables: engine.variableSnapshot)
            shelf.updateProgress(
                bookId: book.id,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                offset: 0
            )
        } catch {
            videoUrl = ""
            state = .failed(SourceError.describe(error))
        }
        isLoadingContent = false
    }

    // MARK: 内存缓存

    /// 写入正文缓存并做条数淘汰（避免长读时内存无限增长）
    private func storeCache(_ url: String, _ value: ChapterContent) {
        contentCache[url] = value
        touchCache(url)
        while contentCacheOrder.count > contentCacheLimit {
            let oldest = contentCacheOrder.removeFirst()
            // 当前章与其邻居不淘汰，否则刚读完就被清掉
            let keep = Set([currentChapter?.url].compactMap { $0 })
            if keep.contains(oldest) {
                contentCacheOrder.append(oldest)
                break
            }
            contentCache[oldest] = nil
        }
    }

    private func touchCache(_ url: String) {
        contentCacheOrder.removeAll { $0 == url }
        contentCacheOrder.append(url)
    }

    func preloadNeighbors() {
        guard let engine else { return }
        let neighbors = [currentIndex + 1, currentIndex + 2].filter { chapters.indices.contains($0) }
        for index in neighbors {
            let chapter = chapters[index]
            guard contentCache[chapter.url] == nil else { continue }
            let info = bookInfoMap
            let chapterInfo: [String: String] = [
                "title": chapter.title, "url": chapter.url,
                "index": String(chapter.index), "bookUrl": book.bookUrl
            ]
            Task { [weak self] in
                guard let self else { return }
                if let result = try? await engine.content(
                    chapterUrl: chapter.url, bookInfo: info, chapterInfo: chapterInfo, chapterTitle: chapter.title
                ) {
                    self.storeCache(chapter.url, result)
                }
            }
        }
    }

    // MARK: 整本离线缓存

    /// 是否正在下载整本
    var isCachingAll: Bool { cacheProgress.isRunning }

    /// 正在下载整本时按钮上的进度文案
    var cacheAllText: String {
        if cacheProgress.isRunning {
            return "缓存中 " + cacheProgress.text
        }
        return cachedChapterCount > 0
            ? "已缓存 " + String(cachedChapterCount) + "/" + String(chapters.count)
            : "缓存整本"
    }

    /// 下载整本（已缓存的章节自动跳过）
    func cacheAll() async {
        guard let engine else {
            state = .failed("书源缺失，无法缓存")
            return
        }
        if cacheProgress.isRunning {
            ChapterCache.shared.cancel()
            return
        }
        // 与详情页同理：isCached 只读内存里的 meta，
        // 不先读进来，「已缓存」会全判成未缓存，整本白下一遍。
        await ChapterCache.shared.loadMeta(bookId: book.id)
        ChapterCache.shared.onVariableChange = { [weak self] snapshot in
            guard let self else { return }
            self.shelf.updateVariables(bookId: self.book.id, variables: snapshot)
        }
        ChapterCache.shared.cacheAll(
            book: book,
            chapters: chapters,
            source: engine.source,
            variables: engine.variableSnapshot,
            bookInfo: bookInfoMap
        )
    }

    /// 清理这本书的离线缓存
    func clearCache() {
        ChapterCache.shared.cancel()
        ChapterCache.shared.remove(bookId: book.id)
        contentCache.removeAll()
        contentCacheOrder.removeAll()
        cachedChapterCount = 0
        cacheProgress = ChapterCache.Progress()
    }

    func goNext() async {
        guard currentIndex < chapters.count - 1 else { return }
        await loadContent(index: currentIndex + 1)
    }

    func goPrevious() async {
        guard currentIndex > 0 else { return }
        await loadContent(index: currentIndex - 1)
    }

    func seek(to index: Int) async {
        await loadContent(index: index)
    }
}

