import Foundation
import Combine

/// 订阅源仓库。
///
/// 与 SourceStore 一样按需计算、延迟写盘，
/// 订阅源数量大时也不会在切换开关时卡住界面。
@MainActor
final class RssStore: ObservableObject {

    @Published private(set) var sources: [RssSource] = []
    @Published private(set) var groups: [String] = []
    @Published private(set) var isLoaded = false

    private let fileName = "rssSources.json"
    private var indexMap: [String: Int] = [:]
    private var persistTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init() {
        startLoading()
    }

    /// 后台分块加载。
    /// 与 SourceStore 同理：启动路径上不能做同步大文件解码，
    /// 否则一打开就闪退。
    private func startLoading() {
        let name = fileName
        loadTask = Task { [weak self] in
            let loaded = await Background.run { () -> [RssSource] in
                guard let list = FileStorage.loadArray(RssSource.self, from: name) else { return [] }
                var seen = Set<String>()
                var output: [RssSource] = []
                output.reserveCapacity(list.count)
                for source in list where seen.insert(source.id).inserted {
                    output.append(source)
                }
                return output
            }
            guard let self, !Task.isCancelled else { return }
            var merged = false
            if self.sources.isEmpty {
                self.sources = loaded
            } else {
                let loadedIds = Set(loaded.map { $0.id })
                let pending = self.sources.filter { !loadedIds.contains($0.id) }
                if !pending.isEmpty { merged = true }
                self.sources = pending + loaded
            }
            self.isLoaded = true
            self.rebuildIndex()
            self.rebuildGroups()
            if merged { self.persist() }
        }
    }

    /// 等待首次加载结束
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    // MARK: 读取

    var enabledSources: [RssSource] { sources.filter { $0.enabled } }

    var searchableSources: [RssSource] {
        sources.filter { $0.enabled && $0.hasSearch }
    }

    func source(id: String) -> RssSource? {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return nil }
        return sources[offset]
    }

    private func rebuildIndex() {
        indexMap.removeAll(keepingCapacity: true)
        indexMap.reserveCapacity(sources.count)
        for (offset, source) in sources.enumerated() {
            indexMap[source.id] = offset
        }
    }

    private func rebuildGroups() {
        var set = Set<String>()
        for source in sources {
            for group in source.group.components(separatedBy: ",") {
                let value = group.trimmed
                if !value.isEmpty { set.insert(value) }
            }
        }
        groups = set.sorted()
    }

    /// 合并 300ms 内的多次改动，编码与写盘都在后台
    private func persist() {
        rebuildGroups()
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

    /// 立即落盘（App 进入后台时调用）
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

    @discardableResult
    func add(_ incoming: [RssSource]) -> (added: Int, updated: Int) {
        var merged = sources
        var map: [String: Int] = [:]
        for (offset, source) in merged.enumerated() { map[source.id] = offset }
        var added = 0
        var updated = 0
        for source in incoming {
            if let offset = map[source.id] {
                merged[offset] = source
                updated += 1
            } else {
                map[source.id] = merged.count
                merged.append(source)
                added += 1
            }
        }
        sources = merged
        rebuildIndex()
        persist()
        return (added, updated)
    }

    func remove(ids: Set<String>) {
        sources.removeAll { ids.contains($0.id) }
        rebuildIndex()
        persist()
    }

    func toggle(id: String) {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return }
        sources[offset].enabled.toggle()
        persist()
    }

    func moveToTop(ids: Set<String>) {
        let selected = sources.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        sources.removeAll { ids.contains($0.id) }
        sources.insert(contentsOf: selected, at: 0)
        rebuildIndex()
        persist()
    }

    func removeAll() {
        sources.removeAll()
        rebuildIndex()
        persist()
    }
}
