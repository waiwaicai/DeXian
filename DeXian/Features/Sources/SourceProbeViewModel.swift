import Foundation
import Combine

/// 书源探测的执行端。
///
/// 与搜索页共用同一套「滑动窗口 + 单源超时」策略：上千个源同时跑会
/// 把内存打爆，所以并发必须设闸门；单个源又可能卡死（脚本死循环、
/// 站点不响应），所以每个源都要有独立的超时，不能让一个源把整轮拖住。
@MainActor
final class SourceProbeViewModel: ObservableObject {

    struct Item: Identifiable {
        var id: String
        var name: String
        var type: BookSourceType
        var state: SourceProbe.State?
        var isLoading: Bool

        var isValid: Bool { state?.isValid ?? false }
        var isRemovable: Bool { state?.isRemovable ?? false }
        /// 探测确实失败了（不含用户自己禁用的源，也不含还在跑的）
        var isFailed: Bool {
            if case .invalid = state { return true }
            return false
        }
    }

    /// 探测用的关键词。
    ///
    /// 取书名这类必定有结果的高频词，避免「源能用但恰好没这本书」被误判。
    /// 允许用户改：冷门站点用通用词可能真的一本都搜不到。
    static let defaultKeyword = "剑来"

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var finishedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var renderLimit = 80
    @Published var keyword: String = SourceProbeViewModel.defaultKeyword
    /// 只显示有问题的源（默认开，探测完上千个源时最有用）
    @Published var onlyInvalid = true

    private var runTask: Task<Void, Never>?
    private var indexMap: [String: Int] = [:]

    /// 同时探测的源数量。
    ///
    /// 比搜索页的 6 再低一点：探测是「跑完就丢」的短任务，单位时间内
    /// 建的 JSVirtualMachine 更多，压低并发能让峰值内存更平缓。
    private let concurrentLimit = 4

    /// 单个源的探测上限。
    ///
    /// 探测允许比搜索更激进地放弃：用户要的是「快速筛掉明显坏掉的源」，
    /// 一个源卡 70 秒没有意义，15 秒没结果就判无效，整轮才能在可接受
    /// 的时间内跑完。超时后按无效处理 —— 这类源实际使用中同样会被
    /// 搜索页判超时，清掉是合理的。
    private let perSourceTimeout: TimeInterval = 15

    var validCount: Int { items.filter { $0.isValid }.count }
    /// 探测失败的源总数（含「登录后才能看」这类不建议清理的）。
    /// 用户自己禁用的源不计入 —— 那不算失败。
    var invalidCount: Int {
        items.filter {
            if case .invalid = $0.state { return true }
            return false
        }.count
    }

    /// 可清理的源数量（界面按钮上的数字）
    var removableCount: Int { items.filter { $0.isRemovable }.count }

    var isFinished: Bool { !isRunning && totalCount > 0 && finishedCount >= totalCount }

    /// 当前要展示的行（受「只看无用」开关影响）。
    ///
    /// 这里展示**所有**探测失败的源，而不只是可清理的那些：
    /// 「超时」「无网络」这类失败会被有意保留（见 State.isRemovable），
    /// 但用户仍然有权知道哪些源这次没跑通，界面不能把它们藏起来。
    private var displayedItems: [Item] {
        onlyInvalid ? items.filter { $0.isFailed } : items
    }

    /// 当前要渲染的行。列表可能上千行，一次性铺出来会爆内存。
    var visibleItems: [Item] {
        let base = displayedItems
        return base.count > renderLimit ? Array(base.prefix(renderLimit)) : base
    }

    var hasMore: Bool { displayedItems.count > renderLimit }

    func loadMore() { renderLimit += 80 }

    func start(sources: [BookSource]) {
        runTask?.cancel()
        renderLimit = 80

        // 只探测「可搜索且已启用」的源：不支持的搜索的源探测必然失败，
        // 混进结果里只会让「无效」的数字虚高。
        let targets = sources.filter {
            $0.enabled && !$0.resolvedSearchRequest.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let skipped = sources.filter {
            !($0.enabled && !$0.resolvedSearchRequest.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        items = targets.map { Item(id: $0.id, name: $0.name, type: $0.type, state: nil, isLoading: true) }
            + skipped.map { Item(id: $0.id, name: $0.name, type: $0.type, state: .skipped(reason: "已禁用 / 不支持搜索"), isLoading: false) }
        indexMap.removeAll(keepingCapacity: true)
        indexMap.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() { indexMap[item.id] = offset }

        finishedCount = skipped.count
        totalCount = items.count
        isRunning = true

        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let probeKeyword = word.isEmpty ? Self.defaultKeyword : word
        let limit = concurrentLimit
        let timeout = perSourceTimeout

        runTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: (String, SourceProbe.State).self) { group in
                // 滑动窗口：最多 limit 个源同时在飞，完成一个补一个。
                // 与搜索页同一套策略 —— 上千个源同时建 JSVirtualMachine
                // 会被系统直接杀掉。
                var next = 0
                while next < min(limit, targets.count) {
                    let source = targets[next]
                    next += 1
                    let word = probeKeyword
                    let seconds = timeout
                    group.addTask {
                        let state = await Self.probeWithTimeout(source, keyword: word, seconds: seconds)
                        return (source.id, state)
                    }
                }
                for await (id, state) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    self.apply(id: id, state: state)
                    if next < targets.count {
                        let source = targets[next]
                        next += 1
                        let word = probeKeyword
                        let seconds = timeout
                        group.addTask {
                            let state = await Self.probeWithTimeout(source, keyword: word, seconds: seconds)
                            return (source.id, state)
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.finishPending()
            self.isRunning = false
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        finishPending()
    }

    /// 删除所有判定为「可清理」的源，返回删掉的数量。
    func removableIDs() -> Set<String> {
        Set(items.filter { $0.isRemovable }.map { $0.id })
    }

    /// 删除后把本地行也移除，界面不必再等一次全量探测
    func removeLocally(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        indexMap.removeAll(keepingCapacity: true)
        indexMap.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() { indexMap[item.id] = offset }
        totalCount = items.count
        finishedCount = min(finishedCount, totalCount)
    }

    private func apply(id: String, state: SourceProbe.State) {
        guard let index = indexMap[id], items.indices.contains(index) else { return }
        if items[index].isLoading { finishedCount += 1 }
        items[index].state = state
        items[index].isLoading = false
    }

    private func finishPending() {
        for index in items.indices where items[index].isLoading {
            items[index].isLoading = false
            items[index].state = .invalid(reason: "探测超时")
            finishedCount += 1
        }
    }

    /// 单源超时：到点就按超时判无效，落后的任务自己在后台收尾。
    ///
    /// 不用 withTaskGroup 包超时：任务组返回前必须等所有子任务结束，
    /// 而卡死的源取消不掉，会让整轮卡在这个源上。
    nonisolated private static func probeWithTimeout(
        _ source: BookSource,
        keyword: String,
        seconds: TimeInterval
    ) async -> SourceProbe.State {
        let box = ContinuationBox<SourceProbe.State>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.set(continuation)
                if Task.isCancelled {
                    box.take()?.resume(returning: .invalid(reason: "已取消"))
                    return
                }
                let work = Task {
                    let state = await SourceProbe.probe(source, keyword: keyword)
                    box.take()?.resume(returning: state)
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                    if let pending = box.take() {
                        work.cancel()
                        pending.resume(returning: .invalid(reason: "探测超时"))
                    }
                }
            }
        } onCancel: {
            box.take()?.resume(returning: .invalid(reason: "已取消"))
        }
    }
}
