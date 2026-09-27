import SwiftUI

/// 发现页：按书源分类浏览
struct ExploreView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore

    @StateObject private var viewModel = ExploreViewModel()

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            if sources.exploreSources.isEmpty {
                EmptyStateView(
                    systemImage: "safari",
                    title: "没有可用的发现源",
                    message: "书源需要支持“发现”功能。\n请到“我的 → 书源管理”导入并启用带发现的书源。"
                )
            } else {
                VStack(spacing: 0) {
                    sourcePicker
                    if !viewModel.categories.isEmpty { categoryPicker }
                    bookList
                }
            }
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.selectedSourceId == nil,
               let first = sources.exploreSources.first {
                await viewModel.select(source: first)
            }
        }
    }

    // MARK: 书源选择

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(sources.exploreSources) { source in
                    Button {
                        Task { await viewModel.select(source: source) }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: source.type.iconName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(source.name)
                                .font(.themeCaption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(viewModel.selectedSourceId == source.id
                                         ? .white : Theme.ColorToken.textSecondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            Capsule().fill(viewModel.selectedSourceId == source.id
                                           ? Theme.Palette.brand : Theme.ColorToken.surface)
                        )
                        .overlay(
                            Capsule().stroke(viewModel.selectedSourceId == source.id
                                             ? Color.clear : Theme.ColorToken.separator, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: 分类

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(viewModel.categories) { category in
                    Button {
                        Task { await viewModel.select(category: category) }
                    } label: {
                        Text(category.title ?? "分类")
                            .font(.themeCaption)
                            .fontWeight(viewModel.selectedCategoryId == category.id ? .semibold : .regular)
                            .foregroundStyle(viewModel.selectedCategoryId == category.id
                                             ? Theme.Palette.brand : Theme.ColorToken.textSecondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(viewModel.selectedCategoryId == category.id
                                               ? Theme.Palette.brand.opacity(0.13)
                                               : Theme.ColorToken.surfaceSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.md)
        }
    }

    // MARK: 列表

    private var bookList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.lg) {
                if viewModel.isLoading, viewModel.books.isEmpty {
                    LoadingView(text: "正在加载")
                        .padding(.top, Theme.Spacing.xxl)
                } else if let error = viewModel.errorMessage, viewModel.books.isEmpty {
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "加载失败",
                        message: error,
                        actionTitle: "重试",
                        action: { Task { await viewModel.reload() } }
                    )
                } else if viewModel.books.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "该分类暂无内容",
                        message: "换一个分类试试"
                    )
                } else {
                    ForEach(viewModel.books) { book in
                        NavigationLink {
                            BookDetailView(searchBook: book)
                        } label: {
                            SearchBookRow(book: book)
                                .cardStyle(padding: Theme.Spacing.md)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if book.id == viewModel.books.last?.id {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    }

                    if viewModel.isLoading {
                        ProgressView().padding(.vertical, Theme.Spacing.lg)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }
}

/// 发现页状态
@MainActor
final class ExploreViewModel: ObservableObject {

    @Published private(set) var categories: [ExploreCategory] = []
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var selectedSourceId: String?
    @Published private(set) var selectedCategoryId: String?

    private var source: BookSource?
    private var currentCategory: ExploreCategory?
    private var page = 1
    private var isFinished = false

    func select(source: BookSource) async {
        self.source = source
        selectedSourceId = source.id
        categories = parseCategories(source.exploreUrl)
        books = []
        errorMessage = nil
        isFinished = false
        page = 1

        if let first = categories.first {
            await select(category: first)
        }
    }

    func select(category: ExploreCategory) async {
        selectedCategoryId = category.id
        currentCategory = category
        books = []
        page = 1
        isFinished = false
        await loadPage(reset: true)
    }

    func reload() async {
        await loadPage(reset: true)
    }

    func loadMore() async {
        guard !isLoading, !isFinished else { return }
        page += 1
        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        guard let source, let category, let url = category.url else { return }
        isLoading = true
        defer { isLoading = false }

        let engine = SourceEngine(source: source)
        do {
            let result = try await engine.explore(urlTemplate: url, page: page)
            if result.isEmpty {
                isFinished = true
            }
            if reset {
                books = result
            } else {
                books.append(contentsOf: result)
            }
            errorMessage = nil
        } catch {
            errorMessage = SourceError.describe(error)
            isFinished = true
        }
    }

    private var category: ExploreCategory? { currentCategory }

    /// 解析发现分类（JSON 数组 / 单行 "标题::地址"）
    private func parseCategories(_ raw: String) -> [ExploreCategory] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let array = trimmed.jsonObject as? [Any] {
            return array.compactMap { item in
                guard let dictionary = item as? [String: Any] else { return nil }
                return ExploreCategory(dict: dictionary)
            }
        }

        // "标题::地址" 逐行
        var results: [ExploreCategory] = []
        for line in trimmed.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.contains("::") else { continue }
            let parts = value.components(separatedBy: "::")
            var dictionary: [String: Any] = [:]
            if parts.count >= 1 { dictionary["title"] = parts[0] }
            if parts.count >= 2 { dictionary["url"] = parts[1] }
            results.append(ExploreCategory(dict: dictionary))
        }
        return results
    }
}
