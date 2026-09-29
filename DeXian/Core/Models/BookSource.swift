import Foundation

/// 书源类型：0 文本，1 音频，2 图片(漫画)，3 文件，4 视频
enum BookSourceType: Int, Codable, CaseIterable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
    case video = 4

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .audio: return "听书"
        case .image: return "漫画"
        case .file: return "文件"
        case .video: return "影视"
        }
    }

    var iconName: String {
        switch self {
        case .text: return "book"
        case .audio: return "waveform"
        case .image: return "photo.on.rectangle"
        case .file: return "doc.zipper"
        case .video: return "play.rectangle"
        }
    }
}

/// 搜索规则
struct SearchRule: Codable, Hashable {
    var checkKeyWord: String?
    /// 书籍列表
    var bookList: String?
    var name: String?
    var author: String?
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String?

    init() {}

    init(dict: [String: Any] = [:]) {
        checkKeyWord = dict.str("checkKeyWord", "checkKeyWordRule", "check_key_word")
        bookList = dict.str("bookList", "bookListRule", "book_list", "list")
        name = dict.str("name", "bookName", "book_name", "title")
        author = dict.str("author", "bookAuthor", "book_author")
        kind = dict.str("kind", "category", "class", "type")
        wordCount = dict.str("wordCount", "word_count", "words")
        lastChapter = dict.str("lastChapter", "lastChapterName", "latestChapter", "last_chapter")
        intro = dict.str("intro", "introduction", "desc", "description", "summary")
        coverUrl = dict.str("coverUrl", "cover", "cover_url", "imageUrl", "img")
        bookUrl = dict.str("bookUrl", "url", "book_url", "detailUrl", "link")
    }
}

/// 发现规则
struct ExploreRule: Codable, Hashable {
    var bookList: String?
    var name: String?
    var author: String?
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String?

    init() {}

    init(dict: [String: Any] = [:]) {
        bookList = dict.str("bookList", "bookListRule", "book_list", "list")
        name = dict.str("name", "bookName", "book_name", "title")
        author = dict.str("author", "bookAuthor", "book_author")
        kind = dict.str("kind", "category", "class", "type")
        wordCount = dict.str("wordCount", "word_count", "words")
        lastChapter = dict.str("lastChapter", "lastChapterName", "latestChapter", "last_chapter")
        intro = dict.str("intro", "introduction", "desc", "description", "summary")
        coverUrl = dict.str("coverUrl", "cover", "cover_url", "imageUrl", "img")
        bookUrl = dict.str("bookUrl", "url", "book_url", "detailUrl", "link")
    }
}

/// 详情页规则
struct BookInfoRule: Codable, Hashable {
    var initRule: String?
    var name: String?
    var author: String?
    var kind: String?
    var wordCount: String?
    var lastChapter: String?
    var intro: String?
    var coverUrl: String?
    var tocUrl: String?
    var canReName: String?

    init() {}

    init(dict: [String: Any] = [:]) {
        initRule = dict.str("init", "initRule")
        name = dict.str("name", "bookName", "title")
        author = dict.str("author", "bookAuthor")
        kind = dict.str("kind", "category", "class", "type")
        wordCount = dict.str("wordCount", "word_count", "words")
        lastChapter = dict.str("lastChapter", "lastChapterName", "latestChapter")
        intro = dict.str("intro", "introduction", "desc", "description", "summary")
        coverUrl = dict.str("coverUrl", "cover", "cover_url", "imageUrl", "img")
        tocUrl = dict.str("tocUrl", "toc_url", "catalogUrl", "chapterListUrl")
        canReName = dict.str("canReName", "canRename")
    }
}

/// 目录规则
struct TocRule: Codable, Hashable {
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVip: String?
    var updateTime: String?
    var nextTocUrl: String?
    var chapterInfo: String?

    init() {}

    init(dict: [String: Any] = [:]) {
        chapterList = dict.str("chapterList", "chapter_list", "list", "chapters")
        chapterName = dict.str("chapterName", "name", "title", "chapter_name")
        chapterUrl = dict.str("chapterUrl", "url", "link", "chapter_url")
        isVip = dict.str("isVip", "vip", "is_vip")
        updateTime = dict.str("updateTime", "update_time", "time")
        nextTocUrl = dict.str("nextTocUrl", "nextToc", "next_toc_url", "nextPage")
        chapterInfo = dict.str("chapterInfo", "info")
    }
}

/// 正文规则
struct ContentRule: Codable, Hashable {
    var content: String?
    var nextContentUrl: String?
    var webJs: String?
    var sourceRegex: String?
    var replaceRegex: String?
    var imageStyle: String?
    var payAction: String?

    init() {}

    init(dict: [String: Any] = [:]) {
        content = dict.str("content", "contentRule", "text", "body")
        nextContentUrl = dict.str("nextContentUrl", "nextContent", "next_content_url", "nextPage")
        webJs = dict.str("webJs", "web_js")
        sourceRegex = dict.str("sourceRegex", "source_regex")
        replaceRegex = dict.str("replaceRegex", "replace_regex", "replaceRule")
        imageStyle = dict.str("imageStyle", "image_style")
        payAction = dict.str("payAction", "pay_action", "buyAction")
    }
}

/// 发现分类
struct ExploreCategory: Codable, Hashable, Identifiable {
    var id: String { (title ?? "") + "|" + (url ?? "") + "|" + String(children?.count ?? 0) }
    var title: String?
    var url: String?
    /// 二级分类
    var children: [ExploreCategory]?

    init(dict: [String: Any]) {
        title = dict.str("title", "name", "text")
        url = dict.str("url", "link", "href")
        children = asDictArray(dict.firstValue(["children", "sub", "subList", "categories"]))
            .map { ExploreCategory(dict: $0) }
    }
}

/// 一个完整的书源。
/// 字段命名以 Legado(阅读 3.x) 为准，同时兼容大量历史别名。
struct BookSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var url: String
    var group: String
    var type: BookSourceType
    var enabled: Bool
    var enabledExplore: Bool
    var comment: String
    var customOrder: Int
    var weight: Int

    var header: String
    var concurrentRate: String
    var loginUrl: String
    var loginUi: String
    var loginCheckJs: String
    var coverDecodeJs: String
    var jsLib: String
    var bookSourceComment: String
    var variableComment: String
    var lastUpdateTime: Int
    var respondTime: Int
    var exploreUrl: String
    var searchUrl: String
    var cookieJar: Bool

    var searchRule: SearchRule
    var exploreRule: ExploreRule
    var bookInfoRule: BookInfoRule
    var tocRule: TocRule
    var contentRule: ContentRule
    var ruleReview: String?

    var category: ExploreCategoryList
    var childSources: [BookSource]
    var isCustom: Bool
    var bookSourceTypeRaw: Int

    init(dict: [String: Any]) {
        let urlValue = dict.str("bookSourceUrl", "bookSourceURL", "sourceUrl", "url", "baseUrl", "host") ?? ""
        let nameValue = dict.str("bookSourceName", "sourceName", "name", "title") ?? "未命名书源"
        // 稳定 id：优先用书源自带 key，其次由 name+url 派生，保证重复导入不产生副本。
        id = dict.str("bookSourceKey", "key", "id", "sourceId") ?? "\(nameValue)|\(urlValue)".stableHash

        name = nameValue
        url = Self.stripURLAnnotation(urlValue)
        group = dict.str("bookSourceGroup", "group", "sourceGroup", "category") ?? ""
        type = BookSourceType(rawValue: dict.int("bookSourceType", "type", "sourceType") ?? 0) ?? .text
        enabled = dict.bool(true, "enabled", "enable")
        enabledExplore = dict.bool(true, "enabledExplore", "enableExplore", "exploreEnabled")
        comment = dict.str("bookSourceComment", "comment", "desc", "description") ?? ""
        customOrder = dict.int("customOrder", "order", "sort") ?? 0
        weight = dict.int("weight") ?? 0

        header = Self.normalizeHeader(dict.str("header", "headers", "httpHeaders", "requestHeader") ?? "")
        concurrentRate = dict.str("concurrentRate", "concurrent_rate", "concurrencyRate", "rate") ?? ""
        loginUrl = dict.str("loginUrl", "login_url") ?? ""
        loginUi = Self.jsonText(dict.firstValue(["loginUi", "login_ui", "loginUI"]))
        loginCheckJs = dict.str("loginCheckJs", "login_check_js", "loginCheckJS") ?? ""
        coverDecodeJs = dict.str("coverDecodeJs", "cover_decode_js", "coverDecodeJS") ?? ""
        jsLib = Self.normalizeJsLib(dict.firstValue(["jsLib", "js_lib", "jsLibrary"]))
        bookSourceComment = dict.str("bookSourceComment", "book_comment") ?? ""
        variableComment = dict.str("variableComment", "variable_comment") ?? ""
        lastUpdateTime = dict.int("lastUpdateTime", "last_update_time", "updateTime") ?? 0
        respondTime = dict.int("respondTime", "respond_time", "timeout") ?? 180000
        cookieJar = dict.bool("enabledCookieJar", "cookieJar", "enableCookieJar")

        searchRule = SearchRule(dict: dict.dict("ruleSearch", "searchRule", "rule_search", "search") ?? [:])
        exploreUrl = Self.stripURLAnnotation(Self.normalizeExploreUrl(dict.firstValue(["exploreUrl", "explore_url", "findUrl", "discoverUrl"])))
        searchUrl = Self.stripURLAnnotation(Self.jsonText(dict.firstValue(["searchUrl", "search_url", "ruleSearchUrl", "findUrl"])))
        exploreRule = ExploreRule(dict: dict.dict("ruleExplore", "exploreRule", "rule_explore", "explore") ?? [:])
        bookInfoRule = BookInfoRule(dict: dict.dict("ruleBookInfo", "bookInfoRule", "rule_book_info", "bookInfo") ?? [:])
        tocRule = TocRule(dict: dict.dict("ruleToc", "tocRule", "rule_toc", "toc", "catalog") ?? [:])
        contentRule = ContentRule(dict: dict.dict("ruleContent", "contentRule", "rule_content", "content") ?? [:])
        ruleReview = dict.str("ruleReview", "reviewRule")

        category = ExploreCategoryList(raw: dict.firstValue(["categories", "category", "exploreCategories", "catList"]))
        childSources = asDictArray(dict.firstValue(["childSources", "children", "subSources", "subSourcesList"]))
            .map { BookSource(dict: $0) }
        isCustom = dict.bool("isCustom", "custom")
        bookSourceTypeRaw = dict.int("bookSourceType", "type", "sourceType") ?? 0
    }

    /// 搜索地址：优先 searchUrl，其次 ruleSearch 里的 url 字段。
    /// 返回 (地址, 内联请求选项, 需要 WebView 吗)
    var resolvedSearchRequest: (url: String, options: HTTPRequestOptions) {
        let raw = searchUrl.trimmed
        guard !raw.isEmpty else { return ("", HTTPRequestOptions()) }
        let parsed = HTTPClient.parseURLRule(raw)
        var options = parsed.options
        if parsed.url.contains("webView") || parsed.url.contains("webview") {
            options.webView = true
        }
        return (parsed.url, options)
    }

    /// bookSourceUrl / searchUrl / exploreUrl 允许 `##注释` 后缀，必须剥离，否则会污染请求地址。
    private static func stripURLAnnotation(_ value: String) -> String {
        let raw = value.trimmed
        guard let range = raw.range(of: "##") else { return raw }
        return String(raw[..<range.lowerBound]).trimmed
    }

    private static func jsonText(_ any: Any?) -> String {
        guard let any else { return "" }
        if let text = any as? String { return text }
        if let data = try? JSONSerialization.data(withJSONObject: any, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    /// header 可能是 JSON 字符串，也可能是被 @js 前缀的规则，统一规范化。
    private static func normalizeHeader(_ raw: String) -> String {
        let value = raw.trimmed
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("@js:") || value.hasPrefix("<js>") { return value }
        if value.hasPrefix("{") { return value }
        // 有些源写成 k=v 多行形式
        var result: [String: String] = [:]
        for line in value.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmed
            let val = String(parts[1]).trimmed
            if !key.isEmpty { result[key] = val }
        }
        guard !result.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else { return value }
        return text
    }

    private static func normalizeJsLib(_ any: Any?) -> String {
        guard let any else { return "" }
        if let text = any as? String { return text }
        // jsLib 可以是 {"name": "url", ...} 形式
        if let dict = asDict(any),
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    /// exploreUrl 归一化为 JSON 数组字符串：[{title,url,style}, ...]
    private static func normalizeExploreUrl(_ any: Any?) -> String {
        guard let any else { return "" }
        if let text = any as? String {
            let value = text.trimmed
            if value.hasPrefix("[") { return value }
            // Legado 允许单行 "分类名::url" 用换行分隔
            if value.contains("::") { return buildCategories(from: value) }
            return value
        }
        if let array = asArray(any),
           let data = try? JSONSerialization.data(withJSONObject: array),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let dict = any as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    /// 把 "玄幻::/xuanhuan\n都市::/dushi" 这种写法转成标准 JSON 数组。
    private static func buildCategories(from text: String) -> String {
        var items: [[String: Any]] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmed
            guard !trimmedLine.isEmpty else { continue }
            let parts = trimmedLine.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            let title = parts[0].trimmed
            let url = parts[1].trimmed
            var item: [String: Any] = ["title": title, "url": url]
            if parts.count >= 3 {
                item["style"] = ["layout_flexGrow": asDouble(parts[2]) ?? 1]
            }
            items.append(item)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return text }
        return json
    }
}

/// 发现分类集合：兼容数组 / 单层对象 / JSON 字符串。
struct ExploreCategoryList: Codable, Hashable {
    var items: [ExploreCategory]

    init(raw: Any?) {
        items = asDictArray(raw).map { ExploreCategory(dict: $0) }
    }

    var isEmpty: Bool { items.isEmpty }
}

extension String {
    /// 稳定短哈希：用于生成书源 id，避免重复导入。
    var stableHash: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
