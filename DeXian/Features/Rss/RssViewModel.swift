import Foundation
import Combine

/// 订阅页状态：订阅源 -> 分类 -> 文章列表。
@MainActor
final class RssViewModel: ObservableObject {

    @Published var selectedSourceId: String?
    @Published var selectedCategoryId: String?
    @Published private(set) var sourceName = ""
    @Published private(set) var categories: [RssCategory] = []
    @Published private(set) var articles: [RssArticle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 已加载的页码，用于"加载更多"
    @Published private(set) var loadedPage = 0
    @Published private(set) var nextPageURL: String?

    private var engine: RssEngine?
    private var currentListURL = ""

    /// 切换订阅源
    func select(source: RssSource) async {
        selectedSourceId = source.id
        sourceName = source.name
        categories = source.categories
        selectedCategoryId = nil
        engine = RssEngine(source: source)
        currentListURL = RssSource.resolvedListURL(category: nil, source: source)
        await reload()
    }

    /// 切换分类
    func select(category: RssCategory) async {
        guard let engine else { return }
        selectedCategoryId = category.id
        currentListURL = RssSource.resolvedListURL(category: category, source: engine.source)
        await reload()
    }

    func reload() async {
        await load(reset: true)
    }

    func loadMore() async {
        await load(reset: false)
    }

    var canLoadMore: Bool { nextPageURL != nil }

    private func load(reset: Bool) async {
        guard let engine else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 翻页优先用上一页给出的"下一页"地址；没有时退回 {{page}} 模板
        let urlTemplate: String
        let page: Int
        if reset {
            urlTemplate = currentListURL
            page = 1
        } else if let next = nextPageURL {
            urlTemplate = next
            page = loadedPage + 1
        } else {
            urlTemplate = currentListURL
            page = loadedPage + 1
        }

        do {
            let result = try await engine.articles(urlTemplate: urlTemplate, page: page)
            if reset {
                articles = result.articles
                loadedPage = 1
            } else if !result.articles.isEmpty {
                // 追加时按 link 去重，避免同一页被重复拉取
                let existing = Set(articles.map { $0.link })
                let fresh = result.articles.filter { !existing.contains($0.link) }
                guard !fresh.isEmpty else { nextPageURL = nil; return }
                articles.append(contentsOf: fresh)
                loadedPage = page
            }
            nextPageURL = result.nextPageURL
        } catch {
            if reset { articles = [] }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// 订阅搜索
@MainActor
final class RssSearchViewModel: ObservableObject {
    @Published var keyword = ""
    @Published private(set) var results: [RssArticle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var searchedKeyword = ""

    func search(sources: [RssSource]) async {
        let value = keyword.trimmed
        guard !value.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        searchedKeyword = value
        defer { isLoading = false }

        var collected: [RssArticle] = []
        var seen = Set<String>()
        var failures: [String] = []
        for source in sources where source.hasSearch {
            do {
                let engine = RssEngine(source: source)
                for article in try await engine.search(keyword: value) {
                    let key = article.link + "|" + article.title
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    collected.append(article)
                }
            } catch {
                failures.append(source.name)
            }
        }
        results = collected
        if collected.isEmpty {
            errorMessage = failures.isEmpty
                ? "没有找到相关内容"
                : "以下订阅源搜索失败：" + failures.joined(separator: "、")
        }
    }
}
