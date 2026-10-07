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
    /// 本轮因数量上限而没有被搜索的书源数量（界面用来提示用户）
    @Published private(set) var skippedSourceCount = 0
    /// 已渲染的书源结果数：结果很多时只渲染前一段
    @Published private(set) var renderLimit = 40
    /// 本轮已完成的书源数（含成功与失败），用于界面显示搜索进度
    @Published private(set) var finishedCount = 0
    /// 本轮参与搜索的书源总数
    @Published private(set) var searchedSourceCount = 0

    enum Scope: String, CaseIterable {
        case all = "全部"
        case text = "小说"
        case comic = "漫画"
        case audio = "听书"
        case video = "影视"
    }

    private var searchTask: Task<Void, Never>?
    /// sourceId -> results 下标。
    ///
    /// 书源上千时，若每次都线性扫描找下标，完成一个源就是 O(N)，
    /// 整轮下来 O(N²)，在主线程上累积成肉眼可见的卡顿。
    private var resultIndex: [String: Int] = [:]
    /// 可见结果（有书 / 有错 / 加载中）的缓存。
    ///
    /// 每完成一个书源都会触发界面求值，如果在求值里对几千条结果做全量
    /// filter，整轮搜索就是 O(N²)，在主线程上累积成明显卡顿。
    /// 这里改成惰性重建：写回只置脏标记，真正读取时才重算一次，
    /// 于是每帧最多重算一次，与完成次数无关。
    private var visibleCache: [SourceResult] = []
    private var visibleDirty = true

    /// 同时抓取的书源数量上限。
    ///
    /// 每个书源会建一个 JSVirtualMachine，同时开几百个必然被系统强杀，
    /// 所以必须有闸门。但推进到 8 是安全的：
    /// JSVirtualMachine 是共享堆，「每个源一个实例」并不会各占一份堆内存；
    /// 真正吃内存的是同时在飞的那几个响应体，而 8 个页面体量很小。
    /// 更关键的是 JSEngine.evaluate 内部把所有求值串行化到同一条队列上，
    /// 所以提高这个数字不会让 JS 侧并发度上升，只是让网络等待并行起来 ——
    /// 这正是「几百个源要跑到天亮」的真正瓶颈。
    private let concurrentLimit = 6

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
    /// 这里必须高于「单次请求超时」，而且要高过重试后的总耗时：
    /// fetchContent 把超时抬到 30s，并且超时后还会重试一次，
    /// 也就是说一个源最坏要 60s 才走完。原先设 40s，等于把
    /// 「慢但完全能用」的源提前掐断，用户看到的就是「怎么搜都超时」。
    /// 70s 只用来兜住真正卡死的源（脚本死循环、回调挂起）。
    /// 验证窗口可能等待用户；搜索不能在 70 秒时把这种源取消。
    /// 拉长到 10 分钟仅作为真正卡死的兜底，正常请求仍然由 HTTP 30 秒超时。
    private let perSourceTimeout: TimeInterval = 600

    /// 结果卡片的渲染上限。
    ///
    /// 这里才是真正需要设闸门的地方：几千个书源若一次性铺成页面，
    /// SwiftUI 会为每个卡片建视图树，内存直接爆掉。
    /// 搜索本身不设数量上限（全部书源都会跑），但界面按需增量渲染。
    private let initialRenderLimit = 40

    /// 给单个操作加超时：超时后按失败处理，不会让源永远停在「加载中」。
    ///
    /// 刻意不用 withTaskGroup：任务组在返回前必须等所有子任务结束，
    /// 而某些书源的 JS 会阻塞在同步网络回调里（java.ajax / startBrowserAwait），
    /// 取消并不能把它打断。结果是超时已经把界面标成失败，滑动窗口却仍卡在
    /// 这个源上，后面的源永远轮不到 —— 表现就是「一直加载中，等久了闪退」。
    /// 这里改成「谁先到就用谁」：超时后立即返回，让落后的任务自己在后台收尾。
    nonisolated private static func withTimeout(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Result<[SearchBook], Error>
    ) async -> Result<[SearchBook], Error> {
        let box = ContinuationBox<Result<[SearchBook], Error>>()
        let limit = max(1, seconds)

        // ContinuationBox.take() 本身就是「只成功一次」的原子闸门：
        // 完成 / 超时 / 取消三条路径都只是抢着 take()，谁拿到谁负责恢复，
        // 因此不存在「既没恢复也没人恢复」的窗口（那会让新的一次搜索永久挂住）。
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                // 本轮已被取消（例如用户输完就点了新的搜索）：
                // 立即收尾，否则 continuation 永不恢复，整轮搜索卡死。
                if Task.isCancelled {
                    box.take()?.resume(returning: .failure(NetworkError.timeout))
                    return
                }
                let work = Task {
                    let outcome = await operation()
                    box.take()?.resume(returning: outcome)
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    if let pending = box.take() {
                        // 是我们抢到了超时：顺手取消还在跑的任务
                        work.cancel()
                        pending.resume(returning: .failure(NetworkError.timeout))
                    }
                }
            }
        } onCancel: {
            box.take()?.resume(returning: .failure(NetworkError.timeout))
        }
    }

    var totalCount: Int {
        results.reduce(0) { $0 + $1.books.count }
    }

    func search(keyword: String, sources: [BookSource], page: Int = 1) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        self.keyword = value
        WebAuthPresenter.shared.beginRound()

        let candidates = filtered(sources)
        guard !candidates.isEmpty else {
            results = []
            skippedSourceCount = 0
            return
        }
        // 全部书源都参与搜索：不再截断前 N 个。
        // 用户要的是「一次搜完」，按数量砍掉一半书源对他没有意义。
        let selected = candidates
        skippedSourceCount = 0

        searchTask?.cancel()
        isSearching = true

        renderLimit = initialRenderLimit
        finishedCount = 0
        searchedSourceCount = selected.count
        // 先占位，界面立刻能看到每个源的状态
        results = selected.map { source in
            SourceResult(sourceId: source.id, sourceName: source.name, type: source.type,
                         books: [], error: nil, isLoading: true)
        }
        resultIndex.removeAll(keepingCapacity: true)
        resultIndex.reserveCapacity(results.count)
        for (offset, result) in results.enumerated() { resultIndex[result.sourceId] = offset }
        visibleDirty = true

        let perSource = perSourceTimeout
        searchTask = Task { [weak self] in
            guard let self else { return }
            let limit = self.concurrentLimit
            let total = selected.count
            await withTaskGroup(of: (String, Result<[SearchBook], Error>).self) { group in
                // 滑动窗口：最多 limit 个源同时抓取，完成一个再补一个，
                // 避免几百个源同时建 JSVirtualMachine 把内存打爆。
                var next = 0
                while next < min(limit, total) {
                    let source = selected[next]
                    next += 1
                    group.addTask {
                        let outcome = await Self.withTimeout(perSource) {
                            let engine = SourceEngine(source: source)
                            do {
                                let books = try await engine.search(keyword: value, page: page)
                                return .success(books)
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
                    if next < total {
                        let source = selected[next]
                        next += 1
                        group.addTask {
                            let outcome = await Self.withTimeout(perSource) {
                                let engine = SourceEngine(source: source)
                                do {
                                    let books = try await engine.search(keyword: value, page: page)
                                    return .success(books)
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
        visibleDirty = true
        for index in results.indices where results[index].isLoading {
            results[index].isLoading = false
            finishedCount += 1
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
        guard let index = resultIndex[sourceId], results.indices.contains(index) else { return }
        if results[index].isLoading { finishedCount += 1 }
        visibleDirty = true
        switch outcome {
        case .success(let books):
            // 过滤空结果并按 id 去重：同一本书重复出现会让 ForEach 崩溃
            var seen = Set<String>()
            results[index].books = books.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
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
        case .video: scoped = list.filter { $0.type == .video }
        }
        // 按书源 id 去重：占位结果与 ForEach 都用 sourceId 当 id，
        // 一旦重复，SwiftUI 会以 "Fatal error: Duplicate ID" 直接终止进程。
        var seen = Set<String>()
        return scoped.filter { seen.insert($0.id).inserted }
    }

    /// 结果按书源分组展示（分页渲染，避免一次构建上千个卡片）。
    ///
    /// 搜索期间的结果数组可能有几千条：这里只保留「有书或有错」的条目，
    /// 再按渲染上限截断。返回的是数组副本，因此界面不会因为后台写回
    /// 原始数组而反复重建视图树。
    var groupedResults: [SourceResult] {
        let visible = visibleResults
        return visible.count > renderLimit ? Array(visible.prefix(renderLimit)) : visible
    }

    /// 当前筛选下可见的结果总数（用于「加载更多」文案）
    var visibleResultCount: Int {
        visibleResults.count
    }

    /// 有内容的结果（有书、有错、或仍在加载）。
    ///
    /// 惰性重建：脏标记被置起时才重算，避免每次完成书源都全量 filter。
    private var visibleResults: [SourceResult] {
        if visibleDirty {
            visibleCache = results.filter { !$0.books.isEmpty || $0.error != nil || $0.isLoading }
            visibleDirty = false
        }
        return visibleCache
    }

    /// 追加渲染更多结果卡片
    func loadMoreResults() {
        renderLimit += 40
    }
}

/// 存放超时竞速用的 continuation。
///
/// 超时、任务完成、外部取消三条路径会同时抢着恢复它，
/// 必须保证「只恢复一次」且任何路径都能拿到它。
final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ value: CheckedContinuation<T, Never>) {
        lock.lock()
        continuation = value
        lock.unlock()
    }

    /// 取走（并清空）continuation。
    ///
    /// 这是唯一的原子闸门：完成 / 超时 / 取消三条路径都只是抢着 take()，
    /// 只有第一个能拿到非 nil，因此绝不会重复恢复，也不会没人恢复。
    func take() -> CheckedContinuation<T, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
