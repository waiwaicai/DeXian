import SwiftUI

/// 搜索页：多源并发搜索，结果按书源分组
struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore

    @StateObject private var viewModel = SearchViewModel()
    @State private var input: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            VStack(spacing: 0) {
                searchField
                scopePicker

                if viewModel.groupedResults.isEmpty {
                    emptyOrIdle
                } else {
                    resultList
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.textTertiary)

                TextField("书名或作者", text: $input)
                    .font(.themeBody)
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit(performSearch)

                if !input.isEmpty {
                    Button {
                        input = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.ColorToken.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.ColorToken.separator, lineWidth: 0.8)
            )

            Button(action: performSearch) {
                Text("搜索")
                    .font(.themeCallout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm + 3)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .fill(Theme.Palette.brand)
                    )
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(SearchViewModel.Scope.allCases, id: \.self) { scope in
                    Button {
                        viewModel.scope = scope
                        if !viewModel.keyword.isEmpty { performSearch() }
                    } label: {
                        Text(scope.rawValue)
                            .font(.themeCaption)
                            .fontWeight(viewModel.scope == scope ? .semibold : .regular)
                            .foregroundStyle(viewModel.scope == scope ? .white : Theme.ColorToken.textSecondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(viewModel.scope == scope ? Theme.Palette.accent : Theme.ColorToken.surfaceSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    // MARK: 结果

    /// 每个书源一次最多渲染这么多条，超出的点「展开」再显示。
    private let pageSize = 30

    @State private var expandedSources: Set<String> = []

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if viewModel.skippedSourceCount > 0 {
                    Text("本轮搜索使用前 " + String(viewModel.results.count)
                         + " 个书源，另有 " + String(viewModel.skippedSourceCount)
                         + " 个未参与。可在「书源管理」里禁用不需要的源。")
                        .font(.themeTiny)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                        .padding(.horizontal, Theme.Spacing.page)
                        .padding(.top, Theme.Spacing.md)
                }

                ForEach(viewModel.groupedResults) { result in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        sourceHeader(result)
                        bookCard(result)
                    }
                }

                // 结果卡片分页渲染：书源多时不会一次构建上千个视图
                if viewModel.visibleResultCount > viewModel.groupedResults.count {
                    Button {
                        viewModel.loadMoreResults()
                    } label: {
                        Text("加载更多书源结果（还剩 "
                             + String(viewModel.visibleResultCount - viewModel.groupedResults.count) + " 个）")
                            .font(.themeCallout)
                            .foregroundStyle(Theme.Palette.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    /// 单个书源的结果卡片
    private func bookCard(_ result: SearchViewModel.SourceResult) -> some View {
        let expanded = expandedSources.contains(result.sourceId)
        let visible = expanded ? result.books : Array(result.books.prefix(pageSize))
        return VStack(spacing: 0) {
            ForEach(visible) { book in
                NavigationLink {
                    BookDetailView(searchBook: book)
                } label: {
                    SearchBookRow(book: book, showSource: false)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        addToShelf(book)
                    } label: {
                        Label("加入书架", systemImage: "plus.circle")
                    }
                }

                if book.id != visible.last?.id {
                    Divider()
                        .background(Theme.ColorToken.separator)
                        .padding(.leading, 74)
                }
            }

            if !expanded, result.books.count > pageSize {
                Button {
                    expandedSources.insert(result.sourceId)
                } label: {
                    Text("展开剩余 " + String(result.books.count - pageSize) + " 本")
                        .font(.themeCaption)
                        .foregroundStyle(Theme.Palette.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle(padding: Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.page)
    }

    private func sourceHeader(_ result: SearchViewModel.SourceResult) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: result.type.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)

            Text(result.sourceName)
                .font(.themeHeadline)
                .foregroundStyle(Theme.ColorToken.textPrimary)

            if result.isLoading {
                ProgressView().controlSize(.mini)
            } else if let error = result.error {
                Text(error)
                    .font(.themeCaption)
                    .foregroundStyle(Theme.Palette.danger)
                    .lineLimit(1)
            } else {
                Text(String(result.books.count) + " 本")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.ColorToken.background.opacity(0.96))
    }

    @ViewBuilder
    private var emptyOrIdle: some View {
        if viewModel.isSearching {
            VStack {
                Spacer()
                LoadingView(text: "正在搜索各书源")
                Spacer()
            }
        } else if !viewModel.keyword.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "没有找到结果",
                message: "换个关键词试试，或到“我的 → 书源管理”\n启用更多书源。"
            )
        } else {
            if sources.searchableSources.isEmpty {
                EmptyStateView(
                    systemImage: "text.magnifyingglass",
                    title: "搜索全源",
                    message: "还没有可搜索的书源。\n先到“我的 → 书源管理 → 导入书源”添加。",
                    actionTitle: "去导入书源",
                    action: { appState.selectedTab = .settings }
                )
            } else {
                EmptyStateView(
                    systemImage: "text.magnifyingglass",
                    title: "搜索全源",
                    message: "已启用 " + String(sources.searchableSources.count) + " 个可搜索书源"
                )
            }
        }
    }

    // MARK: 动作

    private func performSearch() {
        isFocused = false
        viewModel.search(keyword: input, sources: sources.sources)
    }

    private func addToShelf(_ book: SearchBook) {
        let shelfBook = ShelfBook(fromSearch: book)
        if shelf.add(shelfBook) {
            appState.show("已加入书架：" + book.name, style: .success)
        } else {
            appState.show("书架里已有这本书")
        }
    }
}
