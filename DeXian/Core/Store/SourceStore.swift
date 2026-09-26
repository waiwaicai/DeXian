import Foundation
import Combine

/// 书源仓库
@MainActor
final class SourceStore: ObservableObject {

    @Published private(set) var sources: [BookSource] = []
    @Published private(set) var groups: [String] = []

    private let fileName = "bookSources.json"

    /// id -> 下标索引。书源数量大时，避免每次查找都线性扫描。
    private var indexMap: [String: Int] = [:]
    /// 写盘任务：合并短时间内的多次改动，避免频繁重编码
    private var persistTask: Task<Void, Never>?

    init() {
        load()
    }

    // MARK: 读取

    /// 启用的书源（结果按需计算，不缓存，避免切换开关时全量重算）
    var enabledSources: [BookSource] {
        sources.filter { $0.enabled }
    }

    var searchableSources: [BookSource] {
        sources.filter { $0.enabled && !$0.searchUrl.trimmed.isEmpty }
    }

    var exploreSources: [BookSource] {
        sources.filter { $0.enabled && $0.enabledExplore && !$0.exploreUrl.trimmed.isEmpty }
    }

    func source(id: String) -> BookSource? {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return nil }
        return sources[offset]
    }

    private func load() {
        if let stored = FileStorage.load([BookSource].self, from: fileName) {
            sources = stored
            rebuildIndex()
        }
        rebuildGroups()
    }

    /// 重建 id 索引
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
                let value = group.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { set.insert(value) }
            }
        }
        groups = set.sorted()
    }

    /// 标记需要写盘。
    ///
    /// 编码与写文件都放到后台，并且合并 300ms 内的多次改动：
    /// 以前每点一次开关都会在主线程做两次全量 JSON 编码，书源多时会明显卡顿。
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

    func add(_ incoming: [BookSource]) -> (added: Int, updated: Int) {
        let merged = SourceImporter.merge(existing: sources, incoming: incoming)
        sources = merged.result
        rebuildIndex()
        persist()
        return (merged.added, merged.updated)
    }

    /// 批量导入：合并计算放到后台线程，避免几千个书源时卡住界面
    func addInBackground(_ incoming: [BookSource]) async -> (added: Int, updated: Int) {
        let current = sources
        let merged = await Background.run {
            SourceImporter.merge(existing: current, incoming: incoming).result
        }
        sources = merged
        rebuildIndex()
        persist()
        // 新增数量 = 合并后比原来多出来的条数；其余命中同 id 即为更新
        let added = max(0, merged.count - current.count)
        return (added, max(0, incoming.count - added))
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

    func toggleExplore(id: String) {
        guard let offset = indexMap[id], sources.indices.contains(offset) else { return }
        sources[offset].enabledExplore.toggle()
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
        persist()
    }

    func moveToTop(ids: Set<String>) {
        let selected = sources.filter { ids.contains($0.id) }
        sources.removeAll { ids.contains($0.id) }
        sources.insert(contentsOf: selected, at: 0)
        rebuildIndex()
        persist()
    }

    func moveToBottom(ids: Set<String>) {
        let selected = sources.filter { ids.contains($0.id) }
        sources.removeAll { ids.contains($0.id) }
        sources.append(contentsOf: selected)
        rebuildIndex()
        persist()
    }

    func setEnabled(_ enabled: Bool, ids: Set<String>) {
        for index in sources.indices where ids.contains(sources[index].id) {
            sources[index].enabled = enabled
        }
        persist()
    }

    /// 导出为 JSON 文本
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
        rebuildIndex()
        persist()
    }
}
