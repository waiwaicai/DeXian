import Foundation

enum BookType: Int, Codable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3

    var displayName: String {
        switch self {
        case .text: return "小说"
        case .audio: return "有声"
        case .image: return "漫画"
        case .file: return "文件"
        }
    }
}

/// 搜索 / 发现得到的书籍条目
struct SearchBook: Codable, Hashable, Identifiable {
    /// 列表展示用的稳定 id。
    ///
    /// 不能只用「书源 + 地址」：书源规则写得松时会有多本书拿到空地址，
    /// 这些书 id 全部相同，SwiftUI 的 ForEach 遇到重复 id 会直接
    /// fatalError 崩溃（列表滚动到重复项时必崩）。这里把书名与作者一起纳入，
    /// 空地址也不再撞车；书架条目另有自己的 id，不受影响。
    var id: String { origin + "|" + bookUrl + "|" + name + "|" + author }
    var name: String
    var author: String
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String
    var origin: String
    var originName: String
    var type: BookType

    var displayAuthor: String {
        let value = author.trimmed
        return value.isEmpty ? "佚名" : value
    }
}

/// 章节
struct BookChapter: Codable, Hashable, Identifiable {
    var id: String { "\(index)|\(url)" }
    var url: String
    var title: String
    var index: Int
    var isVip: Bool = false
    var updateTime: String?
    var tag: String?
    var start: Int?
    var end: Int?
    var variable: String?

    var displayTitle: String {
        let value = title.trimmed
        return value.isEmpty ? "第\(index + 1)章" : value
    }
}

/// 书籍详情
struct BookInfo: Codable, Hashable {
    var name: String = ""
    var author: String = ""
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
    var intro: String?
    var coverUrl: String?
    var tocUrl: String?

    /// 把详情合并进搜索得到的书本信息，空字段不覆盖。
    func merged(over fallback: BookInfo) -> BookInfo {
        BookInfo(
            name: name.isBlank ? fallback.name : name,
            author: author.isBlank ? fallback.author : author,
            kind: kind?.nilIfBlank ?? fallback.kind,
            wordCount: wordCount?.nilIfBlank ?? fallback.wordCount,
            lastChapter: lastChapter?.nilIfBlank ?? fallback.lastChapter,
            intro: intro?.nilIfBlank ?? fallback.intro,
            coverUrl: coverUrl?.nilIfBlank ?? fallback.coverUrl,
            tocUrl: tocUrl?.nilIfBlank ?? fallback.tocUrl
        )
    }
}

/// 书架书籍（本地持久化）
struct ShelfBook: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var author: String
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var bookUrl: String
    var tocUrl: String?
    var origin: String
    var originName: String
    var type: BookType
    var groupId: String?

    var latestChapterTitle: String?
    var totalChapterCount: Int
    var lastReadChapterIndex: Int
    var lastReadChapterTitle: String?
    var lastReadOffset: Int
    var lastReadTime: Date?
    var addedTime: Date
    var canUpdate: Bool
    /// 书源级变量，用于缓存 bookId 等（对应 Legado 的 book.variable）
    var variable: [String: String]
    /// 缓存的目录
    var chapters: [BookChapter]

    init(search: SearchBook, info: BookInfo?, tocUrl: String?, groupId: String? = nil) {
        let resolvedName = (info?.name.nilIfBlank) ?? search.name
        let resolvedAuthor = (info?.author.nilIfBlank) ?? search.author
        id = "\(search.origin)|\(search.bookUrl)"
        name = resolvedName
        author = resolvedAuthor
        coverUrl = info?.coverUrl?.nilIfBlank ?? search.coverUrl
        intro = info?.intro?.nilIfBlank ?? search.intro
        kind = info?.kind?.nilIfBlank ?? search.kind
        bookUrl = search.bookUrl
        self.tocUrl = tocUrl
        origin = search.origin
        originName = search.originName
        type = search.type
        self.groupId = groupId
        latestChapterTitle = info?.lastChapter?.nilIfBlank ?? search.lastChapter
        totalChapterCount = 0
        lastReadChapterIndex = 0
        lastReadChapterTitle = nil
        lastReadOffset = 0
        lastReadTime = nil
        addedTime = Date()
        canUpdate = true
        variable = [:]
        chapters = []
    }

    init(fromSearch search: SearchBook) {
        self.init(search: search, info: nil, tocUrl: nil, groupId: nil)
    }
}

/// 书架分组
struct ShelfGroup: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var order: Int
}

/// 阅读进度
struct ReadProgress: Codable, Hashable {
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var offset: Int
    var updatedAt: Date
}
