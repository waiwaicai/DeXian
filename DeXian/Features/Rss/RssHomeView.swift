import SwiftUI

/// 订阅页：订阅源 -> 分类 -> 文章列表。
/// 没有订阅源时给出引导，避免空白页。
struct RssHomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var rss: RssStore

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            if !rss.isLoaded {
                VStack { Spacer(); LoadingView(text: "正在加载订阅源"); Spacer() }
            } else if rss.sources.isEmpty {
                EmptyStateView(
                    systemImage: "dot.radiowaves.left.and.right",
                    title: "还没有订阅源",
                    message: "订阅源可以订阅网站的文章、图片等内容。\n到「我的 → 订阅源管理」导入 yckceo 的 RSS 订阅源。"
                )
            } else {
                sourceList
            }
        }
        .navigationTitle("订阅")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: Theme.Spacing.lg) {
                    if !rss.searchableSources.isEmpty {
                        NavigationLink {
                            RssSearchView()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    NavigationLink {
                        RssSourceListView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    // MARK: 订阅源竖版列表

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(rss.enabledSources) { source in
                    NavigationLink {
                        RssSourceFeedView(source: source)
                    } label: {
                        RssSourceRow(source: source)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

/// 订阅源详情：分类 + 文章列表（从订阅首页点击进入）。
struct RssSourceFeedView: View {
    let source: RssSource
    @StateObject private var viewModel = RssViewModel()

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if !viewModel.categories.isEmpty { categoryPicker }
                articleList
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel.selectedSourceId == nil else { return }
            await viewModel.select(source: source)
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
                        Text(category.title)
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

    // MARK: 文章列表

    private var articleList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.md) {
                if viewModel.isLoading, viewModel.articles.isEmpty {
                    LoadingView(text: "正在加载文章")
                        .padding(.top, Theme.Spacing.xxl)
                } else if let error = viewModel.errorMessage, viewModel.articles.isEmpty {
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "加载失败",
                        message: error,
                        actionTitle: "重试",
                        action: { Task { await viewModel.reload() } }
                    )
                } else if viewModel.articles.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "该分类暂无内容",
                        message: "换一个分类或订阅源试试"
                    )
                } else {
                    ForEach(viewModel.articles) { article in
                        NavigationLink {
                            RssArticleView(article: article, sourceId: viewModel.selectedSourceId)
                        } label: {
                            RssArticleRow(article: article)
                        }
                        .buttonStyle(.plain)
                    }

                    if viewModel.isLoading {
                        HStack(spacing: Theme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("正在加载")
                                .font(.themeCaption)
                                .foregroundStyle(Theme.ColorToken.textTertiary)
                        }
                        .padding(.vertical, Theme.Spacing.md)
                    } else {
                        Button {
                            Task { await viewModel.loadMore() }
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "arrow.down.circle")
                                Text("加载更多")
                            }
                            .font(.themeCallout)
                            .foregroundStyle(Theme.Palette.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.md)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }
}

/// 文章行：封面 + 标题 + 来源/时间 + 摘要
struct RssArticleRow: View {
    let article: RssArticle
    var showSource = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            if !article.imageUrl.isBlank, let url = URL(string: article.imageUrl) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.ColorToken.surfaceSecondary
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(article.title)
                    .font(.themeHeadline)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if !article.summary.isBlank {
                    Text(article.summary)
                        .font(.themeCaption)
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    if showSource {
                        Text(article.originName)
                            .font(.themeTiny)
                            .foregroundStyle(Theme.Palette.brand)
                    }
                    if !article.pubDate.isBlank {
                        Text(article.pubDate)
                            .font(.themeTiny)
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .cardStyle(padding: Theme.Spacing.md)
        .contentShape(Rectangle())
    }
}

/// 订阅搜索页：跨所有支持搜索的订阅源查找文章。
struct RssSearchView: View {
    @EnvironmentObject private var rss: RssStore

    @StateObject private var viewModel = RssSearchViewModel()
    @State private var keyword = ""

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    if viewModel.isLoading {
                        LoadingView(text: "正在搜索")
                            .padding(.top, Theme.Spacing.xxl)
                    } else if let error = viewModel.errorMessage, viewModel.results.isEmpty {
                        EmptyStateView(
                            systemImage: "magnifyingglass",
                            title: "没有结果",
                            message: error
                        )
                    } else if viewModel.results.isEmpty {
                        EmptyStateView(
                            systemImage: "magnifyingglass",
                            title: "搜索文章",
                            message: "已启用 " + String(rss.searchableSources.count) + " 个可搜索的订阅源"
                        )
                    } else {
                        ForEach(viewModel.results) { article in
                            NavigationLink {
                                RssArticleView(article: article, sourceId: article.origin)
                            } label: {
                                RssArticleRow(article: article, showSource: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
        .navigationTitle("订阅搜索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, prompt: "搜索文章")
        .onSubmit(of: .search) {
            viewModel.keyword = keyword
            Task { await viewModel.search(sources: rss.searchableSources) }
        }
    }
}
