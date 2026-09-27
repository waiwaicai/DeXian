import Foundation
import Combine

/// 搜索状态：并发多源搜索
@MainActor
final class SearchViewModel: ObservableObject {

    struct SourceResult: Identifiable {
        var id: String { sourceId }
        var sourceId: String
        var sourceName: String
        var type: BookSourceType
        var books: [SearchBook]
        var error: String?
        var isLoading: Bool
    }

    @Published var keyword: String = ""
    @Published private(set) var results: [SourceResult] = []
    @Published private(set) var isSearching = false
    @Published var scope: Scope = .all

    enum Scope: String, CaseIterable {
        case all = "全部"
        case text = "小说"
        case comic = "漫画"
        case audio = "听书"
    }

    private var searchTask: Task<Void, Never>?

    /// 同时抓取的书源数量上限。
    ///
    /// 书源动辄几百个：如果每个源都立刻起一个任务，就会同时创建几百个
    /// JSVirtualMachine（每个源一个），内存瞬间飙升被系统强杀。
    /// 压到 6 个既不会给系统压力，整体速度也几乎不受影响。
    private let concurrentLimit = 6

    var totalCount: Int {
        results.reduce(0) { $0 + $1.books.count }
    }

    func search(keyword: String, sources: [BookSource], page: Int = 1) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        self.keyword = value

        let candidates = filtered(sources)
        guard !candidates.isEmpty else {
            results = []
            return
        }

        searchTask?.cancel()
        isSearching = true

        // 先占位，界面立刻能看到每个源的状态
        results = candidates.map { source in
            SourceResult(sourceId: source.id, sourceName: source.name, type: source.type,
                         books: [], error: nil, isLoading: true)
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            let limit = self.concurrentLimit
            let total = candidates.count
            await withTaskGroup(of: (String, Result<[SearchBook], Error>).self) { group in
                // 滑动窗口：最多 limit 个源同时抓取，完成一个再补一个，
                // 避免几百个源同时建 JSVirtualMachine 把内存打爆。
                var next = 0
                while next < min(limit, total) {
                    let source = candidates[next]
                    next += 1
                    group.addTask {
                        let engine = SourceEngine(source: source)
                        do {
                            let books = try await engine.search(keyword: value, page: page)
                            return (source.id, .success(books))
                        } catch {
                            return (source.id, .failure(error))
                        }
                    }
                }
                for await (sourceId, outcome) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    self.apply(sourceId: sourceId, outcome: outcome)
                    if next < total {
                        let source = candidates[next]
                        next += 1
                        group.addTask {
                            let engine = SourceEngine(source: source)
                            do {
                                let books = try await engine.search(keyword: value, page: page)
                                return (source.id, .success(books))
                            } catch {
                                return (source.id, .failure(error))
                            }
                        }
                    }
                }
            }
            self.isSearching = false
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func apply(sourceId: String, outcome: Result<[SearchBook], Error>) {
        guard let index = results.firstIndex(where: { $0.sourceId == sourceId }) else { return }
        switch outcome {
        case .success(let books):
            // 过滤空结果条目
            results[index].books = books.filter { !$0.name.isEmpty }
            results[index].isLoading = false
        case .failure(let error):
            results[index].error = error.localizedDescription
            results[index].isLoading = false
        }
    }

    private func filtered(_ sources: [BookSource]) -> [BookSource] {
        let list = sources.filter { $0.enabled && !$0.searchUrl.trimmed.isEmpty }
        let scoped: [BookSource]
        switch scope {
        case .all: scoped = list
        case .text: scoped = list.filter { $0.type == .text }
        case .comic: scoped = list.filter { $0.type == .image }
        case .audio: scoped = list.filter { $0.type == .audio }
        }
        // 按书源 id 去重：占位结果与 ForEach 都用 sourceId 当 id，
        // 一旦重复，SwiftUI 会以 "Fatal error: Duplicate ID" 直接终止进程。
        var seen = Set<String>()
        return scoped.filter { seen.insert($0.id).inserted }
    }

    /// 结果按书源分组展示
    var groupedResults: [SourceResult] {
        results.filter { !$0.books.isEmpty || $0.error != nil || $0.isLoading }
    }
}
