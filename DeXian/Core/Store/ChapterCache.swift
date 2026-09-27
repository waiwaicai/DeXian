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
    //
    // 这里原先每一次查询都直接在**主线程**上读文件 + 解码 JSON：
    // 打开一章命中一次 content()，读完一章又命中一次 store()，
    // 缓存整本时进度每跳一次还会命中 counts() —— 一本书几千章就是几千次同步 IO。
    // 主线程被反复堵住，轻则界面彻底失去响应（滑动、点按、工具条 4 秒自动隐藏
    // 全部不生效），重则被系统看门狗以 0x8badf00d 直接杀掉，
    // 表现出来就是「点开小说滑动不了」和「一打开就闪退」。
    //
    // 现在磁盘访问全部挪到后台线程，主线程只碰内存里的 metaCache。

    /// 该章节是否已缓存可离线阅读（只读内存，不做 IO）
    func isCached(bookId: String, chapterUrl: String) -> Bool {
        state(bookId: bookId, chapterUrl: chapterUrl) == .done
    }

    func state(bookId: String, chapterUrl: String) -> State {
        metaCache[bookId]?.states[chapterKey(chapterUrl)] ?? .none
    }

    /// 已缓存章节数 / 失败章节数（只读内存，不做 IO）
    func counts(bookId: String) -> (cached: Int, failed: Int, total: Int) {
        guard let meta = metaCache[bookId] else { return (0, 0, 0) }
        var cached = 0, failed = 0
        for (_, value) in meta.states {
            if value == .done { cached += 1 } else if value == .failed { failed += 1 }
        }
        return (cached, failed, meta.states.count)
    }

    /// 把一本书的 meta 读进内存（后台线程）。
    /// 进入阅读页 / 详情页时调用一次，之后的 counts / isCached 全是内存查询。
    func loadMeta(bookId: String) async {
        if metaCache[bookId] != nil { return }
        let file = metaFile(bookId)
        let value = await Background.run { () -> Meta? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Meta.self, from: data)
        }
        if let value, metaCache[bookId] == nil { metaCache[bookId] = value }
    }

    /// 读取已缓存的章节内容（离线阅读入口）。磁盘读取在后台线程。
    func content(bookId: String, chapterUrl: String) async -> ChapterContent? {
        let target = chapterFile(bookId: bookId, chapterUrl: chapterUrl)
        return await Background.run { () -> ChapterContent? in
            guard let data = try? Data(contentsOf: target) else { return nil }
            return try? JSONDecoder().decode(ChapterContent.self, from: data)
        }
    }

    /// 清理一本书的缓存
    func remove(bookId: String) {
        let directory = bookDirectory(bookId)
        metaCache[bookId] = nil
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
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
                    // store 自身是 @MainActor 的，这里 await 会切回主线程；
                    // 真正的编码与写盘已经在这之后跳到后台，主线程不会被堵住。
                    await self?.store(bookId: bookId, name: bookName, origin: origin,
                                      chapterUrl: chapter.url, content: result)
                    await MainActor.run {
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

    /// 单章写入（阅读时顺带缓存）。编码与写盘都在后台线程，
    /// 否则每翻一章都要在主线程上编码一次几万字的正文，翻页会明显卡顿。
    func store(bookId: String, name: String, origin: String, chapterUrl: String, content: ChapterContent) async {
        let directory = bookDirectory(bookId)
        let target = chapterFile(bookId: bookId, chapterUrl: chapterUrl)
        await Background.run {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if let data = try? JSONEncoder().encode(content) {
                try? data.write(to: target, options: .atomic)
            }
        }
        var value = metaCache[bookId] ?? Meta(bookId: bookId, name: name, origin: origin,
                                              updatedAt: Date(), states: [:])
        value.states[chapterKey(chapterUrl)] = .done
        value.updatedAt = Date()
        saveMeta(value)
    }

    func markFailed(bookId: String, name: String, origin: String, chapterUrl: String) {
        var value = metaCache[bookId] ?? Meta(bookId: bookId, name: name, origin: origin,
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

    /// meta 落盘：内存先更新（主线程可立即读到），磁盘写入放后台并合并。
    private func saveMeta(_ value: Meta) {
        metaCache[value.bookId] = value
        let directory = bookDirectory(value.bookId)
        let file = metaFile(value.bookId)
        let snapshot = value
        Task.detached(priority: .utility) {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
