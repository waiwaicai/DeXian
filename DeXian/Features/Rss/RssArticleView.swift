import SwiftUI
import WebKit

/// 文章阅读页。
/// 正文按订阅源的 ruleContent 抽取；没有正文规则时直接展示网页文本，
/// 并保留"用浏览器打开原文"的出口。
struct RssArticleView: View {
    let article: RssArticle
    let sourceId: String?

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var rss: RssStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var state: LoadState = .loading
    @State private var blocks: [RssBlock] = []

    @State private var forceWebView = false

    private var shouldUseWebView: Bool {
        guard let sourceId, let source = rss.source(id: sourceId) else { return false }
        return source.needsWebFallback
    }

    enum LoadState: Equatable {
        case loading, loaded, failed(String)
    }

    var body: some View {
        if shouldUseWebView || forceWebView {
            RSSWebView(urlString: article.link)
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
        ZStack {
            Color(hex: readerPalette.background).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    switch state {
                    case .loading:
                        HStack(spacing: Theme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("正在加载正文")
                                .font(.themeCaption)
                                .foregroundStyle(Theme.ColorToken.textTertiary)
                        }
                        .padding(.top, Theme.Spacing.xl)
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text(message)
                                .font(.themeCallout)
                                .foregroundStyle(Theme.ColorToken.textSecondary)
                            Button {
                                if let url = URL(string: article.link) { openURL(url) }
                            } label: {
                                Text("用浏览器打开原文")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        .padding(.top, Theme.Spacing.xl)
                    case .loaded:
                        contentBlocks
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl * 2)
            }
        }
        .navigationTitle(article.originName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let url = URL(string: article.link) { openURL(url) }
                } label: {
                    Image(systemName: "safari")
                }
            }
        }
        .task(id: article.id) {
            await load()
        }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(article.title)
                .font(.system(size: settings.fontSize + 5, weight: .bold))
                .foregroundStyle(textColor)

            HStack(spacing: Theme.Spacing.sm) {
                if !article.originName.isBlank {
                    Text(article.originName)
                        .font(.themeTiny)
                        .foregroundStyle(Theme.Palette.brand)
                }
                if !article.pubDate.isBlank {
                    Text(article.pubDate)
                        .font(.themeTiny)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                }
                Spacer(minLength: 0)
            }

            Divider()
                .overlay(Theme.ColorToken.separator)
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: 正文

    @ViewBuilder
    private var contentBlocks: some View {
        if blocks.isEmpty {
            Text("这篇文章没有可显示的正文，可点右上角用浏览器打开原文。")
                .font(.themeCallout)
                .foregroundStyle(Theme.ColorToken.textSecondary)
        } else {
            LazyVStack(alignment: .leading, spacing: settings.lineSpacing + 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let value):
                        Text(value)
                            .font(settings.readingFont)
                            .lineSpacing(settings.lineSpacing)
                            .foregroundStyle(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    case .image(let urlString):
                        if let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                                } else if phase.error != nil {
                                    EmptyView()
                                } else {
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                        .fill(Theme.ColorToken.surfaceSecondary)
                                        .frame(height: 160)
                                        .overlay(ProgressView().controlSize(.small))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 配色

    private var textColor: Color {
        if settings.readerFollowsSystem {
            return colorScheme == .dark ? Color(hex: 0xC9CDD4) : Color(hex: 0x2A2D33)
        }
        return Color(hex: settings.readerTheme.textColor)
    }

    private var readerPalette: (background: UInt32, text: UInt32) {
        if settings.readerFollowsSystem {
            return colorScheme == .dark ? (0x101215, 0xC9CDD4) : (0xFAF8F4, 0x2A2D33)
        }
        return (settings.readerTheme.backgroundColor, settings.readerTheme.textColor)
    }

    // MARK: 加载

    private func load() async {
        if shouldUseWebView { return }
        if case .loaded = state { return }
        state = .loading
        guard let sourceId, let source = rss.source(id: sourceId) else {
            state = .failed("订阅源已被删除")
            return
        }
        do {
            let html = try await RssEngine(source: source)
                .articleContent(link: article.link, title: article.title)
            blocks = RssContentRenderer.render(html: html, baseUrl: article.link)
            if blocks.isEmpty { forceWebView = true }
            state = .loaded
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? SourceError.describe(error))
        }
    }
}

/// 文章正文块：文字段落或图片
enum RssBlock {
    case text(String)
    case image(String)
}

/// 用于 singleUrl / JS 渲染 / 表单验证类订阅源。
/// 这类页面不是静态 HTML，交给系统 WebView 保留登录态和脚本执行。
struct RSSWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        if let url = URL(string: urlString) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 把订阅源返回的正文（HTML 或纯文本）转成可渲染的块序列。
enum RssContentRenderer {

    static func render(html: String, baseUrl: String) -> [RssBlock] {
        let value = html.trimmed
        guard !value.isEmpty else { return [] }

        // 纯文本直接按段落切分
        if !value.contains("<") {
            return RuleUtil.cleanText(value)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { RssBlock.text($0) }
        }

        let document = HTMLParser.parse(value)
        let images = CSSSelector.select("img", in: document)
            .compactMap { node -> String? in
                let raw = node.attribute("data-original")
                    ?? node.attribute("data-src")
                    ?? node.attribute("src")
                guard let raw, !raw.isBlank else { return nil }
                let resolved = RuleUtil.absoluteURL(raw, base: baseUrl)
                return resolved.isBlank ? nil : resolved
            }

        let text = document.textWithBreaks
        var blocks: [RssBlock] = RuleUtil.cleanText(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { RssBlock.text($0) }

        // 图片统一附在正文之后，避免打断段落
        blocks.append(contentsOf: images.map { RssBlock.image($0) })
        return blocks
    }
}
