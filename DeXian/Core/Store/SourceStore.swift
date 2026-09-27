import Foundation
import Combine

/// 书源仓库。
///
/// 启动路径上最大的坑在这里：书源文件（yckceo 全量）常常上百 MB，
/// 早期实现是在 `init` 里同步读文件 + 全量 JSON 解码，
/// 而 `SourceStore()` 是 `AppState` 的存储属性、在 App 启动时构造，
/// 于是「一打开就闪退」——主线程在启动瞬间申请了上百 MB 常驻内存被系统杀掉。
///
/// 现在：
/// 1. `init` 不再做任何 IO，改为后台分块解码；
/// 2. 解码完成才回主线程发布，首屏先显示骨架；
/// 3. 去重一律用 `Set`，与书源数量线性相关。
@MainActor
final class SourceStore: ObservableObject {

    @Published private(set) var sources: [BookSource] = []
    @Published private(set) var groups: [String] = []
    /// 首次加载是否已完成（用于界面显示骨架而不是「还没有书源」）
    @Published private(set) var isLoaded = false

    private let fileName = "bookSources.json"

    /// id -> 下标索引。书源数量大时，避免每次查找都线性扫描。
    private var indexMap: [String: Int] = [:]
    /// 写盘任务：合并短时间内的多次改动，避免频繁重编码
    private var persistTask: Task<Void, Never>?
    /// 加载任务：便于测试与外部等待
    private var loadTask: Task<Void, Never>?

    /// 常用筛选结果的缓存。
    ///
    /// 这些属性原先都是每次访问都全量 filter。书源上千时，
    /// 一次界面刷新里被反复读取（设置页、发现页、搜索页各读好几遍），
    /// 会累积成肉眼可见的卡顿。改成写操作后重算一次。
    private var cachedEnabled: [BookSource] = []
    private var cachedSearchable: [BookSource] = []
    private var cachedExplore: [BookSource] = []

    init() {
        startLoading()
    }

    // MARK: 读取

    /// 启用的书源
    var enabledSources: [BookSource] { cachedEnabled }

    /// 可搜索的书源
    var searchableSources: [BookSource] { cachedSearchable }

    /// 可发现的书源
    var exploreSources: [BookSource] { cachedExplore }

    func source(id: String) -> BookSource? {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return nil }
        return sources[offset]
    }

    /// 后台分块加载书源。
    ///
    /// `.mappedIfSafe` + 逐元素解码，峰值内存只取决于单个书源大小，
    /// 与书源总数无关；解码全程不占用主线程。
    private func startLoading() {
        let name = fileName
        loadTask = Task { [weak self] in
            let loaded = await Background.run { () -> [BookSource] in
                guard let list = FileStorage.loadArray(BookSource.self, from: name) else { return [] }
                // 去重：历史版本可能写入了 id 重复的书源，
                // 一旦列表里出现重复 id，SwiftUI 的 ForEach 会直接 fatalError 崩溃。
                var seen = Set<String>()
                var output: [BookSource] = []
                output.reserveCapacity(list.count)
                for source in list where seen.insert(source.id).inserted {
                    output.append(source)
                }
                return output
            }
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded)
        }
    }

    /// 等待首次加载结束。
    ///
    /// 关键：写操作必须先等它，否则「刚启动就导入」会在数据还没读出来时
    /// 拿空数组去合并，把用户原有书源覆盖掉。
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    /// 回填数据并重建派生缓存。
    ///
    /// 合并而不是覆盖：加载是异步的，加载期间用户可能已经导入或删除了书源，
    /// 直接赋值会把这些改动冲掉。
    private func apply(_ list: [BookSource]) {
        var merged = false
        if sources.isEmpty {
            sources = list
        } else {
            let loadedIds = Set(list.map { $0.id })
            let pending = sources.filter { !loadedIds.contains($0.id) }
            if !pending.isEmpty { merged = true }
            sources = pending + list
        }
        isLoaded = true
        rebuildDerived()
        // 加载期间用户已经改过数据：趁现在把合并结果落盘，
        // 否则磁盘上留下的是「只含新改动」的残缺文件。
        if merged { persist() }
    }

    /// 重建索引、分组与筛选缓存
    private func rebuildDerived() {
        indexMap.removeAll(keepingCapacity: true)
        indexMap.reserveCapacity(sources.count)
        for (offset, source) in sources.enumerated() {
            indexMap[source.id] = offset
        }

        var enabled: [BookSource] = []
        var searchable: [BookSource] = []
        var explore: [BookSource] = []
        enabled.reserveCapacity(sources.count)
        searchable.reserveCapacity(sources.count)
        var groupSet = Set<String>()
        for source in sources {
            // 分组统计要覆盖全部书源（含已禁用），
            // 否则「分组」筛选里会看不到只存在于禁用源上的分组。
            for group in source.group.components(separatedBy: ",") {
                let value = group.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { groupSet.insert(value) }
            }
            guard source.enabled else { continue }
            enabled.append(source)
            if !source.searchUrl.trimmed.isEmpty { searchable.append(source) }
            if source.enabledExplore, !source.exploreUrl.trimmed.isEmpty {
                explore.append(source)
            }
        }
        cachedEnabled = enabled
        cachedSearchable = searchable
        cachedExplore = explore
        groups = groupSet.sorted()
    }

    /// 标记需要写盘。
    ///
    /// 编码与写文件都放到后台，并且合并 300ms 内的多次改动。
    /// `saveArray` 是流式写入，编码时不会把全部书源同时驻留内存。
    private func persist() {
        persistTask?.cancel()
        let snapshot = sources
        let name = fileName
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await Background.run {
                FileStorage.saveArray(snapshot, to: name)
            }
        }
    }

    /// 立即落盘（App 进入后台时调用）。
    ///
    /// persist() 有 300ms 合并窗口，若期间被系统挂起，改动会丢。
    /// 这里取消延迟、直接同步写一次。
    func flushPendingWrites() {
        persistTask?.cancel()
        persistTask = nil
        let snapshot = sources
        let name = fileName
        Task.detached(priority: .utility) {
            FileStorage.saveArray(snapshot, to: name)
        }
    }

    // MARK: 写入

    func add(_ incoming: [BookSource]) -> (added: Int, updated: Int) {
        let merged = SourceImporter.merge(existing: sources, incoming: incoming)
        sources = merged.result
        rebuildDerived()
        persist()
        return (merged.added, merged.updated)
    }

    /// 批量导入：合并计算放到后台线程，避免几千个书源时卡住界面
    func addInBackground(_ incoming: [BookSource]) async -> (added: Int, updated: Int) {
        // 必须先等首次加载结束，否则会把「还没读出来的现有书源」当成空数据覆盖掉
        await waitUntilLoaded()
        let current = sources
        let merged = await Background.run {
            SourceImporter.merge(existing: current, incoming: incoming).result
        }
        sources = merged
        rebuildDerived()
        persist()
        // 新增数量 = 合并后比原来多出来的条数；其余命中同 id 即为更新
        let added = max(0, merged.count - current.count)
        return (added, max(0, incoming.count - added))
    }

    func remove(ids: Set<String>) {
        sources.removeAll { ids.contains($0.id) }
        rebuildDerived()
        persist()
    }

    func toggle(id: String) {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return }
        sources[offset].enabled.toggle()
        rebuildDerived()
        persist()
    }

    func toggleExplore(id: String) {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return }
        sources[offset].enabledExplore.toggle()
        rebuildDerived()
        persist()
    }

    func setGroup(_ group: String, ids: Set<String>) {
        for index in sources.indices where ids.contains(sources[index].id) {
            if group.isEmpty {
                sources[index].group = ""
            } else if sources[index].group.isEmpty {
                sources[index].group = group
            } else if !sources[index].group.components(separatedBy: ",").contains(group) {
                sources[index].group += "," + group
            }
        }
        rebuildDerived()
        persist()
    }

    func moveToTop(ids: Set<String>) {
        let selected = sources.filter { ids.contains($0.id) }
        sources.removeAll { ids.contains($0.id) }
        sources.insert(contentsOf: selected, at: 0)
        rebuildDerived()
        persist()
    }

    func moveToBottom(ids: Set<String>) {
        let selected = sources.filter { ids.contains($0.id) }
        sources.removeAll { ids.contains($0.id) }
        sources.append(contentsOf: selected)
        rebuildDerived()
        persist()
    }

    func setEnabled(_ enabled: Bool, ids: Set<String>) {
        for index in sources.indices where ids.contains(sources[index].id) {
            sources[index].enabled = enabled
        }
        rebuildDerived()
        persist()
    }

    /// 导出为 JSON 文本（用户可见，保留格式化）
    func exportJSON(ids: Set<String>? = nil) -> String {
        let selected = ids == nil ? sources : sources.filter { ids!.contains($0.id) }
        guard !selected.isEmpty else { return "[]" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(selected),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    func clearAll() {
        sources = []
        rebuildDerived()
        persist()
    }
}
