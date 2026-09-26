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

    private let fileName = "rssSources.json"
    private var indexMap: [String: Int] = [:]
    private var persistTask: Task<Void, Never>?

    init() {
        load()
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

    private func load() {
        if let stored = FileStorage.load([RssSource].self, from: fileName) {
            sources = stored
            rebuildIndex()
        }
        rebuildGroups()
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
                FileStorage.save(snapshot, to: name)
            }
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
