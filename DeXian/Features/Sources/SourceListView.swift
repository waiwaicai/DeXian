import SwiftUI

/// 书源管理：默认列表走原生 List 以获得系统级左滑操作，
/// 编辑态使用自定义行以显示更丰富的信息。
struct SourceListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore

    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var editing = false
    @State private var selection = Set<String>()
    @State private var showDeleteConfirm = false
    @State private var showGroupPrompt = false
    @State private var groupName = ""

    /// 已渲染的行数：书源很多时只渲染前面一段，滚到底再追加
    @State private var renderLimit = 120
    /// 每页追加的行数
    private let pageSize = 120
    /// 搜索 / 分组筛选的结果缓存，避免每次 body 重算全量
    @State private var filteredCache: [BookSource] = []
    /// 分组计数缓存
    @State private var groupCounts: [String: Int] = [:]

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            if !sources.isLoaded {
                VStack { Spacer(); LoadingView(text: "正在加载书源"); Spacer() }
            } else if sources.sources.isEmpty {
                EmptyStateView(
                    systemImage: "server.rack",
                    title: "还没有书源",
                    message: "导入书源后即可搜索与阅读。\n支持阅读（Legado）格式的 JSON 与分享链接。"
                )
            } else {
                List {
                    if !sources.groups.isEmpty { groupSection(sourceCount: filtered.count) }
                    ForEach(visibleSources) { source in
                        SourceRow(
                            source: source,
                            editing: editing,
                            isSelected: selection.contains(source.id)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editing {
                                if selection.contains(source.id) { selection.remove(source.id) }
                                else { selection.insert(source.id) }
                            }
                        }
                        .listRowBackground(Theme.ColorToken.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                sources.remove(ids: [source.id])
                                appState.show("已删除：" + source.name)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                sources.toggleExplore(id: source.id)
                            } label: {
                                Label(source.enabledExplore ? "禁用发现" : "启用发现",
                                      systemImage: source.enabledExplore ? "eye.slash" : "eye")
                            }
                            .tint(Theme.Palette.accent)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                sources.toggle(id: source.id)
                            } label: {
                                Label(source.enabled ? "禁用" : "启用",
                                      systemImage: source.enabled ? "pause.circle" : "play.circle")
                            }
                            .tint(source.enabled ? Theme.ColorToken.textTertiary : Theme.Palette.success)
                        }
                    }

                    // 书源很多时只渲染前若干行，滚到底手动追加，避免一次构建上千行
                    if filteredCache.count > renderLimit {
                        loadMoreRow
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "搜索书源名称 / 分组")
                .onAppear { refreshFiltered() }
                .onChange(of: sources.sources.count) { _ in refreshFiltered() }
                .onChange(of: searchText) { _ in refreshFiltered() }
                .onChange(of: selectedGroup) { _ in refreshFiltered() }
            }
        }
        .navigationTitle("书源管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if editing { batchBar }
        }
        .alert("删除书源", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                sources.remove(ids: selection)
                selection.removeAll()
                editing = false
                appState.show("已删除所选书源")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 " + String(selection.count) + " 个书源，书架里使用这些书源的书籍可能无法继续阅读。")
        }
        .alert("新建分组", isPresented: $showGroupPrompt) {
            TextField("分组名称", text: $groupName)
            Button("添加") {
                let name = groupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { sources.setGroup(name, ids: selection) }
                groupName = ""
                editing = false
                selection.removeAll()
            }
            Button("取消", role: .cancel) { groupName = "" }
        }
    }

    // MARK: 分组

    private func groupSection(sourceCount: Int) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        selectedGroup = nil
                    } label: {
                        groupChip(title: "全部", count: sources.sources.count, isActive: selectedGroup == nil)
                    }
                    .buttonStyle(.plain)

                    ForEach(sources.groups, id: \.self) { group in
                        Button {
                            selectedGroup = group
                        } label: {
                            groupChip(
                                title: group,
                                count: groupCounts[group] ?? 0,
                                isActive: selectedGroup == group
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            Text("分组 · 共 " + String(sourceCount) + " 个")
        }
    }

    private func groupChip(title: String, count: Int, isActive: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.themeCaption)
            Text(String(count))
                .font(.themeTiny)
                .foregroundStyle(isActive ? .white.opacity(0.85) : Theme.ColorToken.textTertiary)
        }
        .foregroundStyle(isActive ? .white : Theme.ColorToken.textSecondary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(Capsule().fill(isActive ? Theme.Palette.brand : Theme.ColorToken.surfaceSecondary))
    }

    // MARK: 批量操作

    private var batchBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button(selection.count == filtered.count ? "取消全选" : "全选") {
                if selection.count == filtered.count { selection.removeAll() }
                else { selection = Set(filtered.map { $0.id }) }
            }
            .font(.themeCallout)

            Spacer()

            Menu {
                Button {
                    sources.setEnabled(true, ids: selection)
                    appState.show("已启用 " + String(selection.count) + " 个")
                } label: { Label("启用所选", systemImage: "checkmark.circle") }

                Button {
                    sources.setEnabled(false, ids: selection)
                } label: { Label("禁用所选", systemImage: "pause.circle") }

                Button { showGroupPrompt = true } label: { Label("添加分组", systemImage: "folder.badge.plus") }

                Button {
                    sources.moveToTop(ids: selection)
                } label: { Label("置顶", systemImage: "arrow.up.to.line") }

                Button {
                    sources.moveToBottom(ids: selection)
                } label: { Label("置底", systemImage: "arrow.down.to.line") }

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: { Label("删除所选", systemImage: "trash") }
            } label: {
                Label(String(selection.count) + " 项", systemImage: "ellipsis.circle")
                    .font(.themeCallout)
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: Theme.Spacing.md) {
                // 编辑态下不再显示探测入口：批量操作栏已经占满底部，
                // 再挂一个入口容易误触。
                if !editing {
                    NavigationLink {
                        SourceProbeView()
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                }

                Button(editing ? "完成" : "管理") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        editing.toggle()
                        selection.removeAll()
                    }
                }
                .font(.themeCallout)
            }
        }
    }

    /// 当前筛选结果（来自缓存，body 不重复计算）
    private var filtered: [BookSource] { filteredCache }

    /// 当前实际渲染的行（分页）。
    ///
    /// 这里再按 id 去重一次：List/ForEach 只要拿到重复 id 就会
    /// fatalError 崩溃，导入的书源数据不可信，渲染前必须兜住。
    private var visibleSources: [BookSource] {
        var seen = Set<String>()
        let unique = filteredCache.filter { seen.insert($0.id).inserted }
        return unique.count > renderLimit ? Array(unique.prefix(renderLimit)) : unique
    }

    /// 重新计算筛选结果与分组计数
    private func refreshFiltered() {
        var list = sources.sources
        if let selectedGroup {
            list = list.filter { SourceListView.groups(of: $0).contains(selectedGroup) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || $0.group.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
            }
        }
        filteredCache = list
        // 换筛选条件后回到首页，避免沿用上一次的大页码
        if renderLimit > pageSize, list.count < renderLimit {
            renderLimit = max(pageSize, list.count)
        }

        var counts: [String: Int] = [:]
        for source in sources.sources {
            for group in SourceListView.groups(of: source) {
                counts[group, default: 0] += 1
            }
        }
        groupCounts = counts
    }

    /// 拆分书源分组字段（一次拆分，避免多处重复 components）
    private static func groups(of source: BookSource) -> [String] {
        source.group
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 列表底部的「加载更多」行
    private var loadMoreRow: some View {
        Button {
            renderLimit += pageSize
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "arrow.down.circle")
                Text("继续加载 · 已显示 " + String(min(renderLimit, filteredCache.count))
                     + " / " + String(filteredCache.count))
                    .font(.themeCaption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.brand)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .buttonStyle(.plain)
    }
}

/// 书源行
struct SourceRow: View {
    let source: BookSource
    var editing: Bool
    var isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if editing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Theme.Palette.brand : Theme.ColorToken.textTertiary)
            }

            Image(systemName: source.type.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(source.enabled ? Theme.Palette.brand : Theme.ColorToken.textTertiary)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(source.name)
                        .font(.themeBody)
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                        .lineLimit(1)

                    if !source.group.isEmpty {
                        Text(source.group.components(separatedBy: ",").first ?? "")
                            .font(.themeTiny)
                            .foregroundStyle(Theme.Palette.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Palette.accent.opacity(0.13)))
                    }
                }

                Text(source.url)
                    .font(.themeTiny)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.xs) {
                    if source.enabledExplore, !source.exploreUrl.isEmpty {
                        badge("发现", color: Theme.Palette.success)
                    }
                    if !source.searchUrl.isEmpty {
                        badge("搜索", color: Theme.Palette.brand)
                    }
                    if !source.enabled {
                        badge("已禁用", color: Theme.ColorToken.textTertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(source.enabled ? 1 : 0.55)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.themeTiny)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
    }
}
