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
    /// 10 个既能跑满网络，JSVM 数量也远低于危险线。
    private let concurrentLimit = 5

    /// 单个书源的抓取上限。
    ///
    /// 原先是「整轮 60 秒」的全局死线：几百个源排队跑，60 秒一到，
    /// 还没轮到启动的源会被统一标记成「已跳过（搜索超时）」。
    /// 用户看到的就是「全部都超时」，其实绝大多数源根本没被搜过。
    /// 改成按源计时，并把整轮窗口按源数量放大，每个源都有机会真正跑一次。
    ///
    /// 取值必须高于「单次 HTTP 请求的上限」（HTTPClient 里是 30s，
    /// fetchContent 还会把它抬到至少 30s）。若设得比请求超时还短，
    /// 那些「慢但能用」的源会被这里提前掐断，又变成假的「全部超时」。
    /// 40s 只用来兜住真正卡死的源（脚本死循环、回调挂起）。
    private let perSourceTimeout: TimeInterval = 40

    /// 整轮搜索的上限：按「源数量 / 并发数 × 单源上限」估算，再留一倍余量。
    private func deadline(for total: Int) -> TimeInterval {
        let wave = Double(total) / Double(concurrentLimit)
        return min(max(90, wave * perSourceTimeout * 2), 600)
    }

    /// 给单个操作加超时：超时后按失败处理，不会让源永远停在「加载中」。
    /// 之前某些源会卡在加载中一直不返回，是「等久了就闪退」的直接原因。
    nonisolated private static func withTimeout(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Result<[SearchBook], Error>
    ) async -> Result<[SearchBook], Error> {
        await withTaskGroup(of: Optional<Result<[SearchBook], Error>>.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            // 先返回的那个为准：要么是抓取结果，要么是超时（nil）
            for await first in group {
                group.cancelAll()
                return first ?? .failure(NetworkError.timeout)
            }
            return .failure(NetworkError.timeout)
        }
    }

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

        let perSource = perSourceTimeout
        searchTask = Task { [weak self] in
            guard let self else { return }
            let limit = self.concurrentLimit
            let total = candidates.count
            let started = Date()
            let timeLimit = self.deadline(for: total)
            func outOfTime() -> Bool { Date().timeIntervalSince(started) > timeLimit }
            await withTaskGroup(of: (String, Result<[SearchBook], Error>).self) { group in
                // 滑动窗口：最多 limit 个源同时抓取，完成一个再补一个，
                // 避免几百个源同时建 JSVirtualMachine 把内存打爆。
                var next = 0
                while next < min(limit, total) {
                    let source = candidates[next]
                    next += 1
                    group.addTask {
                        let outcome = await Self.withTimeout(perSource) {
                            let engine = SourceEngine(source: source)
                            do {
                                return .success(try await engine.search(keyword: value, page: page))
                            } catch {
                                return .failure(error)
                            }
                        }
                        return (source.id, outcome)
                    }
                }
                for await (sourceId, outcome) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    self.apply(sourceId: sourceId, outcome: outcome)
                    if next < total, !outOfTime() {
                        let source = candidates[next]
                        next += 1
                        group.addTask {
                            let outcome = await Self.withTimeout(perSource) {
                                let engine = SourceEngine(source: source)
                                do {
                                    return .success(try await engine.search(keyword: value, page: page))
                                } catch {
                                    return .failure(error)
                                }
                            }
                            return (source.id, outcome)
                        }
                    }
                }
            }
            // 未跑完的源收尾，避免一直转圈。
            self.finishPending()
            self.isSearching = false
        }
    }

    /// 把仍在加载中的条目标记为完成（用于超时 / 取消后的收尾）。
    private func finishPending() {
        for index in results.indices where results[index].isLoading {
            results[index].isLoading = false
            if results[index].books.isEmpty, results[index].error == nil {
                results[index].error = "未搜索（已停止）"
            }
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
            results[index].error = SourceError.describe(error)
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
