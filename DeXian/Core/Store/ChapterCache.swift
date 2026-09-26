import Foundation
import Combine

/// 整本离线缓存。
///
/// 书源站点的正文随时可能失效，阅读时逐章联网也很费流量；
/// 这里把下载好的章节存成本地文件，断网也能继续读。
/// 存储布局：
/// ```
/// Caches/DeXian/<书籍id哈希>/meta.json      书籍元信息与章节状态
/// Caches/DeXian/<书籍id哈希>/<章节id哈希>.json  单章正文与图片
/// ```
/// 这样单章内容是独立小文件，不必把整本书塞进一个 JSON，
/// 既能边下边读，也不会因为一本书过大而在编解码时爆内存。
@MainActor
final class ChapterCache: ObservableObject {

    /// 章节缓存状态
    enum State: String, Codable {
        /// 未缓存
        case none
        /// 已缓存
        case done
        /// 下载失败
        case failed
    }

    struct Meta: Codable {
        var bookId: String
        var name: String
        var origin: String
        var updatedAt: Date
        /// 章节地址 -> 状态
        var states: [String: State]
    }

    /// 下载进度
    struct Progress: Equatable {
        var total: Int = 0
        var finished: Int = 0
        var failed: Int = 0
        var isRunning: Bool = false

        var fraction: Double {
            total > 0 ? Double(finished + failed) / Double(total) : 0
        }

        var text: String {
            if !isRunning, total == 0 { return "" }
            var value = String(finished) + "/" + String(total)
            if failed > 0 { value += "（失败 " + String(failed) + "）" }
            return value
        }
    }

    /// 全局单例：书架与阅读页共用同一份缓存索引
    static let shared = ChapterCache()

    @Published private(set) var progress = Progress()

    private var metaCache: [String: Meta] = [:]
    private let rootDirectory: URL
    private var downloadTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeXian", isDirectory: true)
        rootDirectory = base
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
    }

    // MARK: 查询

    /// 该章节是否已缓存可离线阅读
    func isCached(bookId: String, chapterUrl: String) -> Bool {
        state(bookId: bookId, chapterUrl: chapterUrl) == .done
    }

    func state(bookId: String, chapterUrl: String) -> State {
        meta(bookId: bookId)?.states[chapterKey(chapterUrl)] ?? .none
    }

    /// 已缓存章节数 / 失败章节数
    func counts(bookId: String) -> (cached: Int, failed: Int, total: Int) {
        guard let meta = meta(bookId: bookId) else { return (0, 0, 0) }
        var cached = 0, failed = 0
        for (_, value) in meta.states {
            if value == .done { cached += 1 } else if value == .failed { failed += 1 }
        }
        return (cached, failed, meta.states.count)
    }

    /// 读取已缓存的章节内容（离线阅读入口）
    func content(bookId: String, chapterUrl: String) -> ChapterContent? {
        let target = chapterFile(bookId: bookId, chapterUrl: chapterUrl)
        guard let data = try? Data(contentsOf: target) else { return nil }
        return try? JSONDecoder().decode(ChapterContent.self, from: data)
    }

    /// 清理一本书的缓存
    func remove(bookId: String) {
        try? FileManager.default.removeItem(at: bookDirectory(bookId))
        metaCache[bookId] = nil
    }

    // MARK: 下载

    /// 取消正在进行的整本下载
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        progress.isRunning = false
    }

    /// 整本下载。
    ///
    /// - 串行抓取：并发过高容易被书源站点限流，也会让内存与电量飙升；
    /// - 每章抓完立刻落盘，中途退出已下载的部分依然可用；
    /// - 已缓存的章节直接跳过，重复点击只会补齐缺失部分；
    /// - 抓取与解析放在 detached 任务里，进度回主线程更新，不卡界面。
    func cacheAll(
        book: ShelfBook,
        chapters: [BookChapter],
        source: BookSource?,
        variables: [String: String],
        bookInfo: [String: String]
    ) {
        guard let source, !chapters.isEmpty else { return }
        downloadTask?.cancel()
        let pending = chapters.filter { !isCached(bookId: book.id, chapterUrl: $0.url) }
        progress = Progress(total: pending.count, finished: 0, failed: 0, isRunning: true)
        guard !pending.isEmpty else {
            progress.isRunning = false
            return
        }

        let bookId = book.id
        let bookName = book.name
        let origin = book.origin
        let bookUrl = book.bookUrl
        downloadTask = Task.detached(priority: .utility) { [weak self] in
            let engine = SourceEngine(source: source, variables: variables)
            for chapter in pending {
                if Task.isCancelled { break }
                let chapterInfo: [String: String] = [
                    "title": chapter.title,
                    "url": chapter.url,
                    "index": String(chapter.index),
                    "baseUrl": chapter.url,
                    "bookUrl": bookUrl
                ]
                do {
                    let result = try await engine.content(
                        chapterUrl: chapter.url,
                        bookInfo: bookInfo,
                        chapterInfo: chapterInfo,
                        chapterTitle: chapter.title
                    )
                    if Task.isCancelled { break }
                    let snapshot = engine.variableSnapshot
                    await MainActor.run {
                        self?.store(bookId: bookId, name: bookName, origin: origin,
                                    chapterUrl: chapter.url, content: result)
                        self?.progress.finished += 1
                        self?.onVariableChange?(snapshot)
                    }
                } catch {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.markFailed(bookId: bookId, name: bookName, origin: origin,
                                         chapterUrl: chapter.url)
                        self?.progress.failed += 1
                    }
                }
            }
            await MainActor.run { self?.progress.isRunning = false }
        }
    }

    /// 每章抓完后回传书源变量（有些站点靠 token 续读）
    var onVariableChange: (([String: String]) -> Void)?

    /// 单章写入（阅读时顺带缓存）
    func store(bookId: String, name: String, origin: String, chapterUrl: String, content: ChapterContent) {
        let directory = bookDirectory(bookId)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let data = try? JSONEncoder().encode(content) {
            try? data.write(to: chapterFile(bookId: bookId, chapterUrl: chapterUrl), options: .atomic)
        }
        var value = meta(bookId: bookId) ?? Meta(bookId: bookId, name: name, origin: origin,
                                                updatedAt: Date(), states: [:])
        value.states[chapterKey(chapterUrl)] = .done
        value.updatedAt = Date()
        saveMeta(value)
    }

    func markFailed(bookId: String, name: String, origin: String, chapterUrl: String) {
        var value = meta(bookId: bookId) ?? Meta(bookId: bookId, name: name, origin: origin,
                                                updatedAt: Date(), states: [:])
        value.states[chapterKey(chapterUrl)] = .failed
        value.updatedAt = Date()
        saveMeta(value)
    }

    // MARK: 落盘

    private func chapterKey(_ url: String) -> String {
        url.stableHash
    }

    private func bookDirectory(_ bookId: String) -> URL {
        rootDirectory.appendingPathComponent(bookId.stableHash, isDirectory: true)
    }

    private func metaFile(_ bookId: String) -> URL {
        bookDirectory(bookId).appendingPathComponent("meta.json")
    }

    private func chapterFile(bookId: String, chapterUrl: String) -> URL {
        bookDirectory(bookId).appendingPathComponent(chapterKey(chapterUrl) + ".json")
    }

    private func meta(bookId: String) -> Meta? {
        if let cached = metaCache[bookId] { return cached }
        guard let data = try? Data(contentsOf: metaFile(bookId)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Meta.self, from: data) else { return nil }
        metaCache[bookId] = value
        return value
    }

    private func saveMeta(_ value: Meta) {
        metaCache[value.bookId] = value
        let directory = bookDirectory(value.bookId)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: metaFile(value.bookId), options: .atomic)
    }
}
