import Foundation
import Combine

/// 书架持久化快照。
///
/// 刻意放在文件作用域而不是嵌在 `ShelfStore` 里：
/// 嵌套类型会继承外层的 `@MainActor` 隔离，
/// 导致它无法在后台线程解码（而书架 JSON 有几十 MB，必须离开主线程）。
private struct ShelfSnapshot: Codable {
    var books: [ShelfBook]
    var groups: [ShelfGroup]
}

/// 书架仓库
@MainActor
final class ShelfStore: ObservableObject {

    @Published private(set) var books: [ShelfBook] = []
    @Published private(set) var groups: [ShelfGroup] = []

    private let fileName = "shelf.json"
    /// 异步加载任务：便于测试与外部等待
    private var loadTask: Task<Void, Never>?
    /// 写盘任务：合并短时间内的多次改动
    private var persistTask: Task<Void, Never>?
    /// 首次加载是否完成
    @Published private(set) var isLoaded = false

    init() {
        startLoading()
    }

    /// 后台加载书架。
    ///
    /// 书架里每本书都内嵌了完整目录（几百到几千章），
    /// 书多时 JSON 可以到几十 MB。原先在 init 里同步解码，
    /// 而 ShelfStore 是 AppState 的存储属性、启动即构造，
    /// 上百 MB 的瞬时内存会让 App 一启动就被系统杀掉。
    private func startLoading() {
        let name = fileName
        loadTask = Task { [weak self] in
            let snapshot = await Background.run { FileStorage.load(ShelfSnapshot.self, from: name) }
            guard let self, !Task.isCancelled else { return }
            var merged = false
            if let snapshot {
                // 合并而不是覆盖：加载期间用户可能已经加了书，
                // 直接赋值会把刚加的那本冲掉。
                let loadedIds = Set(snapshot.books.map { $0.id })
                let pending = self.books.filter { !loadedIds.contains($0.id) }
                if !pending.isEmpty { merged = true }
                self.books = pending + snapshot.books
                self.groups = snapshot.groups
            }
            self.isLoaded = true
            if merged { self.persist() }
        }
    }

    /// 等待首次加载结束（测试与依赖数据的流程使用）
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    // MARK: 查询

    func book(id: String) -> ShelfBook? {
        books.first { $0.id == id }
    }

    func books(inGroup groupId: String?) -> [ShelfBook] {
        guard let groupId else { return books }
        return books.filter { $0.groupId == groupId }
    }

    func contains(bookUrl: String, origin: String, name: String = "", author: String = "") -> Bool {
        let id = ShelfBook.identifier(origin: origin, bookUrl: bookUrl, name: name, author: author)
        return books.contains { $0.id == id }
    }

    /// 找不到完全匹配时，再按「书源 + 书名 + 作者」兜底查找。
    ///
    /// 空地址的 api 书源在补丁前会以「书源|空地址」入库，
    /// 现在写入用的是带书名的新 id，需要能把这个旧条目找回来。
    func book(origin: String, bookUrl: String, name: String, author: String) -> ShelfBook? {
        let id = ShelfBook.identifier(origin: origin, bookUrl: bookUrl, name: name, author: author)
        if let exact = books.first(where: { $0.id == id }) { return exact }
        return books.first {
            $0.origin == origin && $0.name == name && $0.author == author
        }
    }

    /// 立即落盘（App 进入后台时调用），避免 300ms 合并窗口内的改动丢失
    func flushPendingWrites() {
        persistTask?.cancel()
        persistTask = nil
        let snapshot = ShelfSnapshot(books: books, groups: groups)
        let name = fileName
        Task.detached(priority: .utility) {
            FileStorage.save(snapshot, to: name)
        }
    }

    // MARK: 写入

    @discardableResult
    func add(_ book: ShelfBook) -> Bool {
        // 加载未完成时不写入，避免稍后回填书架时把刚加的书冲掉
        guard !books.contains(where: { $0.id == book.id }) else { return false }
        books.insert(book, at: 0)
        persist()
        return true
    }

    func remove(ids: Set<String>) {
        books.removeAll { ids.contains($0.id) }
        persist()
    }

    func update(_ book: ShelfBook) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        persist()
    }

    func updateProgress(bookId: String, chapterIndex: Int, chapterTitle: String, offset: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[index].lastReadChapterIndex = chapterIndex
        books[index].lastReadChapterTitle = chapterTitle
        books[index].lastReadOffset = offset
        books[index].lastReadTime = Date()
        persist()
    }

    func updateChapters(bookId: String, chapters: [BookChapter]) {
        guard let index = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[index].chapters = chapters
        books[index].totalChapterCount = chapters.count
        if let last = chapters.last { books[index].latestChapterTitle = last.title }
        persist()
    }

    /// 把书源抓取过程中产生的变量写回书架（跨会话复用）
    func updateVariables(bookId: String, variables: [String: String]) {
        guard let index = books.firstIndex(where: { $0.id == bookId }) else { return }
        guard books[index].variable != variables else { return }
        books[index].variable = variables
        persist()
    }

    func moveToTop(id: String) {
        guard let index = books.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let book = books.remove(at: index)
        books.insert(book, at: 0)
        persist()
    }

    func addGroup(name: String) {
        let group = ShelfGroup(id: UUID().uuidString, name: name, order: groups.count)
        groups.append(group)
        persist()
    }

    func removeGroup(id: String) {
        groups.removeAll { $0.id == id }
        for index in books.indices where books[index].groupId == id { books[index].groupId = nil }
        persist()
    }

    func assign(bookIds: Set<String>, toGroup groupId: String?) {
        for index in books.indices where bookIds.contains(books[index].id) {
            books[index].groupId = groupId
        }
        persist()
    }

    // MARK: 持久化

    /// 写盘：合并 300ms 内的多次改动，并在后台线程编码。
    ///
    /// 书架每本书内嵌完整目录，整份 JSON 可能几十 MB。
    /// 原先在主线程同步编码，翻一章就会卡一下；书多时更明显。
    private func persist() {
        persistTask?.cancel()
        let snapshot = ShelfSnapshot(books: books, groups: groups)
        let name = fileName
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await Background.run {
                FileStorage.save(snapshot, to: name)
            }
        }
    }
}
