import Foundation
import Combine

/// 书架仓库
@MainActor
final class ShelfStore: ObservableObject {

    @Published private(set) var books: [ShelfBook] = []
    @Published private(set) var groups: [ShelfGroup] = []

    private let fileName = "shelf.json"

    init() {
        load()
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

    // MARK: 写入

    @discardableResult
    func add(_ book: ShelfBook) -> Bool {
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

    private struct Snapshot: Codable {
        var books: [ShelfBook]
        var groups: [ShelfGroup]
    }

    private func load() {
        if let snapshot = FileStorage.load(Snapshot.self, from: fileName) {
            books = snapshot.books
            groups = snapshot.groups
        }
    }

    private func persist() {
        FileStorage.save(Snapshot(books: books, groups: groups), to: fileName)
    }
}
