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
    private var contentCache: [String: ChapterContent] = [:]
    private var loadTask: Task<Void, Never>?
    private var cacheObserver: AnyCancellable?

    init(book: ShelfBook, source: BookSource?, shelf: ShelfStore) {
        self.book = book
        self.shelf = shelf
        engine = source.map { SourceEngine(source: $0, variables: book.variable) }
        chapters = book.chapters
        currentIndex = book.lastReadChapterIndex
        cachedChapterCount = ChapterCache.shared.counts(bookId: book.id).cached
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

    /// 是否漫画模式
    var isComic: Bool {
        book.type == .image || (book.type == .text && !images.isEmpty && content.isEmpty)
    }

    // MARK: 目录

    func loadTocIfNeeded() async {
        if !chapters.isEmpty { return }
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
            state = .failed(SourceError.describe(error))
        }
    }

    func reloadToc() async {
        chapters = []
        content = ""
        images = []
        audioUrl = ""
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

        let chapter = chapters[index]

        if let cached = contentCache[chapter.url] {
            content = cached.text
            images = cached.images
            state = .loaded
            return
        }

        // 离线缓存优先：断网也能读
        if let offline = ChapterCache.shared.content(bookId: book.id, chapterUrl: chapter.url) {
            contentCache[chapter.url] = offline
            content = offline.text
            images = offline.images
            state = .loaded
            return
        }

        loadTask?.cancel()
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
                if Task.isCancelled { return }
                self.contentCache[chapter.url] = result
                self.content = result.text
                self.images = result.images
                self.state = .loaded
                ChapterCache.shared.store(
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
                if Task.isCancelled { return }
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
                    self.contentCache[chapter.url] = result
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
    func cacheAll() {
        guard let engine else {
            state = .failed("书源缺失，无法缓存")
            return
        }
        if cacheProgress.isRunning {
            ChapterCache.shared.cancel()
            return
        }
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

