import SwiftUI

/// 订阅源管理：列表 + 导入入口。
/// 默认列表走原生 List 以获得系统级左滑操作，风格与书源管理保持一致。
struct RssSourceListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var rss: RssStore

    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var showImport = false
    @State private var showDeleteAllConfirm = false

    /// 已渲染的行数：订阅源很多时只渲染前面一段
    @State private var renderLimit = 120
    private let pageSize = 120

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            if rss.sources.isEmpty {
                EmptyStateView(
                    systemImage: "dot.radiowaves.left.and.right",
                    title: "还没有订阅源",
                    message: "订阅源可订阅网站的文章、图片等内容。\n支持 yckceo 的 RSS 订阅源 JSON。",
                    actionTitle: "导入订阅源",
                    action: { showImport = true }
                )
            } else {
                List {
                    if !rss.groups.isEmpty { groupSection }
                    ForEach(visibleSources) { source in
                        RssSourceRow(source: source)
                            .listRowBackground(Theme.ColorToken.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    rss.remove(ids: [source.id])
                                    appState.show("已删除：" + source.name)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    rss.moveToTop(ids: [source.id])
                                } label: {
                                    Label("置顶", systemImage: "arrow.up.to.line")
                                }
                                .tint(Theme.Palette.accent)
                            }
                    }
                    if visibleSources.count < filtered.count {
                        loadMoreRow
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "搜索订阅源")
            }
        }
        .navigationTitle("订阅源管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showImport = true
                    } label: {
                        Label("导入订阅源", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        copyAll()
                    } label: {
                        Label("导出全部", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label("清空订阅源", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showImport) {
            NavigationStack {
                ImportRssSourceView()
            }
        }
        .alert("清空订阅源？", isPresented: $showDeleteAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                rss.removeAll()
                appState.show("已清空订阅源")
            }
        } message: {
            Text("将删除全部 " + String(rss.sources.count) + " 个订阅源，该操作不可撤销。")
        }
    }

    // MARK: 分组

    private var groupSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                groupChip(title: "全部", count: rss.sources.count, active: selectedGroup == nil) {
                    selectedGroup = nil
                }
                ForEach(rss.groups, id: \.self) { group in
                    groupChip(
                        title: group,
                        count: rss.sources.filter { $0.group.contains(group) }.count,
                        active: selectedGroup == group
                    ) {
                        selectedGroup = group
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func groupChip(title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title).font(.themeCaption)
                Text(String(count)).font(.themeTiny).opacity(0.7)
            }
            .foregroundStyle(active ? .white : Theme.ColorToken.textSecondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 6)
            .background(Capsule().fill(active ? Theme.Palette.brand : Theme.ColorToken.surfaceSecondary))
        }
        .buttonStyle(.plain)
    }

    private var loadMoreRow: some View {
        Button {
            renderLimit += pageSize
        } label: {
            HStack {
                Spacer()
                Text("加载更多（还剩 " + String(filtered.count - visibleSources.count) + " 个）")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.Palette.brand)
                Spacer()
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: 数据

    private var filtered: [RssSource] {
        var list = rss.sources
        if let selectedGroup {
            list = list.filter { $0.group.components(separatedBy: ",").contains(selectedGroup) }
        }
        let keyword = searchText.trimmed
        if !keyword.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                    || $0.url.localizedCaseInsensitiveContains(keyword)
            }
        }
        return list
    }

    /// 同书源列表：渲染前按 id 去重，避免 ForEach 重复 id 直接崩溃。
    private var visibleSources: [RssSource] {
        var seen = Set<String>()
        let unique = filtered.filter { seen.insert($0.id).inserted }
        return Array(unique.prefix(renderLimit))
    }

    private func copyAll() {
        let payload = rss.sources.map { source -> String in
            var dictionary: [String: Any] = [
                "sourceName": source.name,
                "sourceUrl": source.url,
                "sourceIcon": source.icon,
                "sourceGroup": source.group,
                "sourceComment": source.comment,
                "enabled": source.enabled,
                "enabledCookieJar": source.enabledCookieJar,
                "enableJs": source.enableJs,
                "loadWithBaseUrl": source.loadWithBaseUrl,
                "singleUrl": source.singleUrl,
                "articleStyle": source.articleStyle,
                "customOrder": source.customOrder,
                "type": source.type,
                "sortUrl": source.sortUrl,
                "searchUrl": source.searchUrl,
                "ruleArticles": source.ruleArticles,
                "ruleNextPage": source.ruleNextPage,
                "ruleTitle": source.ruleTitle,
                "rulePubDate": source.rulePubDate,
                "ruleDescription": source.ruleDescription,
                "ruleImage": source.ruleImage,
                "ruleLink": source.ruleLink,
                "ruleContent": source.ruleContent
            ]
            if !source.header.isBlank { dictionary["header"] = source.header }
            if !source.jsLib.isBlank { dictionary["jsLib"] = source.jsLib }
            let data = (try? JSONSerialization.data(withJSONObject: dictionary, options: [.withoutEscapingSlashes])) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
        UIPasteboard.general.string = "[" + payload.joined(separator: ",") + "]"
        appState.show("已复制 " + String(rss.sources.count) + " 个订阅源到剪贴板", style: .success)
    }
}

/// 订阅源行
struct RssSourceRow: View {
    let source: RssSource

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .fill(source.enabled
                          ? Theme.Palette.brand.opacity(0.14)
                          : Theme.ColorToken.surfaceSecondary)
                    .frame(width: 34, height: 34)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(source.enabled ? Theme.Palette.brand : Theme.ColorToken.textTertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.themeHeadline)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.sm) {
                    Text(source.url)
                        .font(.themeTiny)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                        .lineLimit(1)
                    if source.hasArticleRule {
                        Text("规则源")
                            .font(.themeTiny)
                            .foregroundStyle(Theme.Palette.brand)
                    }
                    if source.hasSearch {
                        Text("可搜索")
                            .font(.themeTiny)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
