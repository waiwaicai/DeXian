import SwiftUI

/// 阅读页：自动区分文字与漫画
struct ReaderView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel: ReaderViewModel
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showChrome = true
    /// 章节切换令牌：变化时正文与漫画都回到顶部
    @State private var scrollTick = 0
    /// 是否切到听书界面（文本书源也可用系统语音朗读）
    @State private var audioMode = false

    init(book: ShelfBook, source: BookSource?, shelf: ShelfStore) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(book: book, source: source, shelf: shelf))
    }

    var body: some View {
        ZStack {
            readerBackground

            contentArea

            // 轻点分区层：夹在内容与浮层之间。
            // 只有点击手势、没有拖动识别，所以下面的正文与漫画照常滚动；
            // 又位于 chromeOverlay 之下，底部按钮的点击不会被它截走。
            tapLayer

            if showChrome {
                chromeOverlay
            } else if viewModel.isComic, !viewModel.images.isEmpty {
                comicBadge
            }
        }
        .navigationBarBackButtonHidden(true)
        // 导航栏常驻。
        // 原先随 showChrome 显示/隐藏会改变顶部安全区，正文被迫重排，
        // 看上去就是「一点正文，字号和排序全变了」。改为常驻后布局稳定，
        // showChrome 只控制底部工具条。
        .toolbar(.visible, for: .navigationBar)
        .toolbar { toolbarContent }
        .onChange(of: viewModel.currentIndex) { _ in
            scrollTick &+= 1
            showChrome = false
        }
        .task {
            await viewModel.loadTocIfNeeded()
            if viewModel.content.isEmpty, !viewModel.chapters.isEmpty {
                await viewModel.loadContent(index: viewModel.currentIndex)
            }
            if !viewModel.isAudio {
                viewModel.preloadNeighbors()
            }
        }
        .sheet(isPresented: $showCatalog) {
            CatalogView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
        }
    }

    /// 漫画模式下的极简状态条：当前页码 / 总页数
    private var comicBadge: some View {
        VStack {
            Spacer()
            Text(String(viewModel.images.count) + " 页 · " + viewModel.progressText)
                .font(.themeTiny)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Capsule().fill(.black.opacity(0.4)))
                .padding(.bottom, Theme.Spacing.lg)
                .allowsHitTesting(false)
        }
    }

    /// 工具条文字色：深色背景下用浅色
    private var chromeTextColor: Color {
        readerPalette.background == 0xFAF8F4 ? Theme.ColorToken.textPrimary : Color(hex: 0xE8EAEE)
    }

    // MARK: 手势层

    /// 轻点分区层。
    ///
    /// 用 SpatialTapGesture 取点击坐标：带 (CGPoint) -> Void 的
    /// onTapGesture 重载要 iOS 17，本工程部署目标是 iOS 16。
    private var tapLayer: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handleTap(x: value.location.x / max(geometry.size.width, 1))
                        }
                )
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// 轻点分区：左 30% 上一章、右 30% 下一章、中间 40% 收展工具条。
    ///
    /// 原先整屏只有一个「切换菜单」的响应，点正文永远不会翻页；
    /// 而且翻章藏在双击里，用户根本发现不了。改成三分区后单击即可翻章。
    private func handleTap(x: CGFloat) {
        // 听书与漫画都是连续滚动，误触翻章体验很差，只收展工具条
        if isAudioSurface || viewModel.isComic {
            withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
            return
        }
        if x < 0.3 {
            Task { await viewModel.goPrevious() }
        } else if x > 0.7 {
            Task { await viewModel.goNext() }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
        }
    }

    // MARK: 背景

    /// 阅读背景：优先用用户选择的配色；选择"跟随系统"时按深浅色取默认
    private var readerBackground: some View {
        Color(hex: readerPalette.background).ignoresSafeArea()
    }

    /// 当前生效的阅读配色
    private var readerPalette: (background: UInt32, text: UInt32) {
        if settings.readerFollowsSystem {
            return colorScheme == .dark
                ? (0x101215, 0xC9CDD4)
                : (0xFAF8F4, 0x2A2D33)
        }
        return (settings.readerTheme.backgroundColor, settings.readerTheme.textColor)
    }

    // MARK: 内容

    /// 音频源本身，或用户主动切到听书界面
    private var isAudioSurface: Bool { viewModel.isAudio || audioMode }

    @ViewBuilder
    private var contentArea: some View {
        if !viewModel.hasSource {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "书源缺失",
                message: "这本书对应的书源已被删除，请重新添加书源后换源阅读。"
            )
        } else {
            switch viewModel.state {
            case .loading where viewModel.chapters.isEmpty:
                VStack { Spacer(); LoadingView(text: "正在获取目录"); Spacer() }

            case .failed(let message) where viewModel.content.isEmpty
                && viewModel.images.isEmpty && viewModel.audioUrl.isEmpty:
                EmptyStateView(
                    systemImage: "wifi.exclamationmark",
                    title: "加载失败",
                    message: message,
                    actionTitle: "重试",
                    action: {
                        Task {
                            await viewModel.reloadToc()
                            await viewModel.loadContent(index: viewModel.currentIndex)
                        }
                    }
                )

            default:
                if isAudioSurface {
                    AudioReaderView(viewModel: viewModel)
                } else if viewModel.isComic {
                    ComicReaderView(
                        images: viewModel.images,
                        fitWidth: settings.comicFitWidth,
                        referer: viewModel.currentChapter?.url ?? "",
                        sourceKey: viewModel.book.origin
                    )
                    .id(scrollTick)
                } else {
                    TextReaderView(viewModel: viewModel)
                        .id(scrollTick)
                }
            }
        }
    }

    // MARK: 阅读时浮层（点击中间区域切换）

    /// 阅读浮层：只保留底部工具条。
    ///
    /// 顶部信息交给常驻导航栏显示。原先这里还有一条 topBar，
    /// 与导航栏叠成两层；而且导航栏随 showChrome 显隐会改变顶部安全区，
    /// 正文被迫重排，用户看到的就是「一弹出顶部框，字就重排/变大小」。
    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            cacheProgressBar
            bottomBar
        }
        .transition(.opacity)
    }

    /// 整本缓存进度条：下载中才出现
    private var cacheProgressBar: some View {
        Group {
            if viewModel.cacheProgress.total > 0 {
                VStack(spacing: Theme.Spacing.xs) {
                    ProgressView(value: viewModel.cacheProgress.fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.Palette.brand)
                    HStack {
                        Text(viewModel.cacheProgress.isRunning ? "正在缓存整本" : "缓存完成")
                            .font(.themeTiny)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                        Spacer()
                        Text(viewModel.cacheProgress.text)
                            .font(.themeTiny)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.sm)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.xl) {
            chromeButton("目录", systemImage: "list.bullet") { showCatalog = true }

            Spacer()

            chromeButton("上一章", systemImage: "chevron.left") {
                Task { await viewModel.goPrevious() }
            }
            .disabled(viewModel.currentIndex == 0)

            chromeButton("下一章", systemImage: "chevron.right") {
                Task { await viewModel.goNext() }
            }
            .disabled(viewModel.currentIndex >= viewModel.chapters.count - 1)

            Spacer()

            if viewModel.isAudio {
                chromeButton("隐藏", systemImage: "chevron.down") { showChrome = false }
            } else if audioMode {
                chromeButton("退出听书", systemImage: "text.alignleft") { audioMode = false }
            } else {
                chromeButton("听书", systemImage: "headphones") { audioMode.toggle() }

                chromeButton("界面", systemImage: "textformat.size") { showSettings = true }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    private func chromeButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.themeTiny)
            }
            .foregroundStyle(chromeTextColor)
            .frame(minWidth: 52)
        }
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 顶部标题：章节名 + 进度。常驻显示，布局稳定。
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(viewModel.currentChapter?.title ?? viewModel.book.name)
                    .font(.themeCaptionBold)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(1)
                if settings.showProgress {
                    Text(viewModel.progressText)
                        .font(.themeTiny)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                }
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showCatalog = true
                } label: { Label("目录", systemImage: "list.bullet") }

                Button {
                    showSettings = true
                } label: { Label("排版设置", systemImage: "textformat.size") }

                if !viewModel.isAudio {
                    Button {
                        audioMode.toggle()
                    } label: {
                        Label(audioMode ? "退出听书" : "听书", systemImage: audioMode ? "book" : "headphones")
                    }
                }

                Button {
                    viewModel.cacheAll()
                } label: {
                    Label(viewModel.cacheAllText,
                          systemImage: viewModel.isCachingAll ? "stop.circle" : "arrow.down.circle")
                }
                .disabled(viewModel.chapters.isEmpty || viewModel.isAudio)

                if viewModel.cachedChapterCount > 0 {
                    Button(role: .destructive) {
                        viewModel.clearCache()
                    } label: { Label("清理离线缓存", systemImage: "trash") }
                }

                Button {
                    Task { await viewModel.reloadToc() }
                } label: { Label("刷新目录", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - 文字阅读

struct TextReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    chapterTitle

                    if viewModel.isLoadingContent, viewModel.content.isEmpty {
                        loadingIndicator
                    } else {
                        // 逐段渲染：段落间距真实可控，长文排版更稳
                        VStack(alignment: .leading, spacing: CGFloat(settings.paragraphSpacing)) {
                            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(settings.readingFont)
                                    .lineSpacing(settings.lineSpacing)
                                    .foregroundStyle(textColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                        .id("content")
                    }

                    chapterFooter
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xxl + Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xxl * 2)
            }
            .onChange(of: viewModel.currentIndex) { _ in
                proxy.scrollTo("content", anchor: .top)
            }
        }
    }

    private var chapterTitle: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(viewModel.currentChapter?.title ?? "")
                .font(.system(size: settings.fontSize + 5, weight: .bold))
                .foregroundStyle(textColor)

            Rectangle()
                .fill(Theme.ColorToken.separator)
                .frame(height: 1)
                .padding(.bottom, Theme.Spacing.sm)
        }
    }

    private var loadingIndicator: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("正在加载正文")
                .font(.themeCaption)
                .foregroundStyle(Theme.ColorToken.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.xxl)
    }

    private var chapterFooter: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Divider().background(Theme.ColorToken.separator)

            HStack(spacing: Theme.Spacing.lg) {
                Button {
                    Task { await viewModel.goPrevious() }
                } label: {
                    Text("上一章")
                        .font(.themeCallout)
                }
                .disabled(viewModel.currentIndex == 0)

                Spacer()

                Text(viewModel.progressText)
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textTertiary)

                Spacer()

                Button {
                    Task { await viewModel.goNext() }
                } label: {
                    Text("下一章")
                        .font(.themeCallout)
                }
                .disabled(viewModel.currentIndex >= viewModel.chapters.count - 1)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .padding(.top, Theme.Spacing.xxl)
    }

    /// 正文分段：空行丢弃，段首按设置决定是否缩进两格
    private var paragraphs: [String] {
        let value = viewModel.content
        guard !value.isEmpty else { return [] }
        var output: [String] = []
        for line in value.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            output.append(settings.textIndent ? "　　" + trimmed : trimmed)
        }
        return output
    }

    /// 正文颜色：与 ReaderView 的背景选择保持一致
    private var textColor: Color {
        if settings.readerFollowsSystem {
            return colorScheme == .dark ? Color(hex: 0xC9CDD4) : Color(hex: 0x2A2D33)
        }
        return Color(hex: settings.readerTheme.textColor)
    }
}

// MARK: - 漫画阅读

struct ComicReaderView: View {
    let images: [String]
    var fitWidth: Bool
    /// 章节页地址，用作图片 Referer
    var referer: String = ""
    /// 所属书源 id：带上该源 Cookie，登录后才能看的漫画才出图
    var sourceKey: String?

    /// 已放行的页数：滚动到底再追加，避免一次性解码整章几十张原图。
    @State private var window = 8
    private let step = 8

    var body: some View {
        if images.isEmpty {
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: "本章没有图片",
                message: "该章节未解析到图片，可能是付费章节或书源规则需要更新。"
            )
        } else {
            ZStack(alignment: .bottom) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(images.prefix(window).enumerated()), id: \.offset) { index, url in
                            ComicPageView(url: url, fitWidth: fitWidth, referer: referer, sourceKey: sourceKey)
                                .onAppear {
                                    // 快到底时再追加下一页，图像解码量始终有界
                                    if index >= window - 2, window < images.count {
                                        window = min(window + step, images.count)
                                    }
                                }
                        }
                    }
                    .padding(.top, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.xxl)

                    if window < images.count {
                        ProgressView()
                            .padding(.vertical, Theme.Spacing.lg)
                    }
                }

                Text(String(min(window, images.count)) + " / " + String(images.count))
                    .font(.themeTiny)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(.bottom, Theme.Spacing.lg)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 单页漫画（等比展示、可加载失败重试）
struct ComicPageView: View {
    let url: String
    var fitWidth: Bool
    /// 正文所在页地址，作为图片请求的 Referer（多数图站会校验）
    var referer: String = ""
    /// 所属书源 id
    var sourceKey: String?

    @State private var image: UIImage?
    @State private var failed = false
    /// 重试次数：用于触发重新加载（不再污染 URL）
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fitWidth ? .fit : .fill)
                    .frame(maxWidth: .infinity)
            } else if failed {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                    Text("图片加载失败")
                        .font(.themeCaption)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                    Text("可能是图床防盗链或网络异常")
                        .font(.themeTiny)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                    Button("重试") {
                        failed = false
                        attempt += 1
                        Task { await load(force: true) }
                    }
                    .font(.themeCaption)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(Theme.ColorToken.surfaceSecondary.opacity(0.4))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .task(id: attempt) {
            await load(force: attempt > 0)
        }
    }

    private func load(force: Bool) async {
        guard image == nil else { return }
        // 按屏幕宽度做下采样：漫画原图常有 3000px 宽，
        // 全尺寸解码一屏就是几百 MB，滚动几页必被系统杀掉。
        let maxPixel = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        if !force, let cached = ImageCache.shared.image(for: url + "|" + String(Int(maxPixel))) {
            image = cached
            return
        }
        let loaded = await ImageLoader.shared.image(
            url: url,
            maxPixel: maxPixel,
            referer: referer,
            sourceKey: sourceKey
        )
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}


// MARK: - 目录

struct CatalogView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var ascending = true
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredChapters) { chapter in
                    Button {
                        dismiss()
                        Task { await viewModel.seek(to: chapter.index) }
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(chapter.title)
                                .font(.themeBody)
                                .foregroundStyle(chapter.index == viewModel.currentIndex
                                                 ? Theme.Palette.brand
                                                 : Theme.ColorToken.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if chapter.index == viewModel.currentIndex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.Palette.brand)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "搜索章节")
            .navigationTitle("目录 · " + String(viewModel.chapters.count) + " 章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // 正序 / 倒序：默认正序（第 1 章在最上）
                    Button {
                        ascending.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: ascending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
                            Text(ascending ? "正序" : "倒序")
                                .font(.themeTiny)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var filteredChapters: [BookChapter] {
        let list = query.isEmpty
            ? viewModel.chapters
            : viewModel.chapters.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return ascending ? list : Array(list.reversed())
    }
}

// MARK: - 排版设置

struct ReaderSettingsSheet: View {
    @EnvironmentObject private var settings: SettingsStore

    private var previewBackground: Color {
        settings.readerFollowsSystem
            ? Theme.ColorToken.surfaceSecondary
            : Color(hex: settings.readerTheme.backgroundColor)
    }

    private var previewText: Color {
        settings.readerFollowsSystem
            ? Theme.ColorToken.textPrimary
            : Color(hex: settings.readerTheme.textColor)
    }

    /// 配色选项：左侧圆形色块 + 名称
    private func themeChip(_ item: SettingsStore.ReaderTheme) -> some View {
        let active = !settings.readerFollowsSystem && settings.readerTheme == item
        return Button {
            settings.readerTheme = item
            settings.readerFollowsSystem = false
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color(hex: item.backgroundColor))
                        .frame(width: 22, height: 22)
                    Circle()
                        .stroke(Color(hex: item.textColor), lineWidth: 3)
                        .frame(width: 13, height: 13)
                }
                .overlay(Circle().stroke(Theme.ColorToken.separator, lineWidth: 0.8))

                Text(item.displayName)
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(active ? Theme.Palette.brand.opacity(0.14) : Theme.ColorToken.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(active ? Theme.Palette.brand : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    // 黑底绿字等组合，点一下立即应用到阅读页
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: Theme.Spacing.sm)],
                              spacing: Theme.Spacing.sm) {
                        ForEach(SettingsStore.ReaderTheme.allCases, id: \.self) { item in
                            themeChip(item)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)

                    Toggle("跟随系统深浅色", isOn: $settings.readerFollowsSystem)
                }

                Section("字号") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                        Slider(value: $settings.fontSize, in: 14...30, step: 1)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                        Text(String(Int(settings.fontSize)))
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                    // 实时预览：用所选字体与配色显示一行示例
                    Text("得闲 · 示例正文 Aa 123")
                        .font(settings.readingFont)
                        .lineSpacing(settings.lineSpacing)
                        .foregroundStyle(previewText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(previewBackground)
                        )
                }

                Section("行距") {
                    Slider(value: $settings.lineSpacing, in: 0...24, step: 1)
                }

                Section("字体") {
                    Picker("字体", selection: $settings.fontFamily) {
                        ForEach(SettingsStore.fontFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)

                    // 段落间距：长文阅读时拉开段落更省眼
                    HStack {
                        Text("段落间距")
                        Slider(value: $settings.paragraphSpacing, in: 0...30, step: 2)
                        Text(String(Int(settings.paragraphSpacing)))
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                }

                Section("翻页") {
                    Picker("翻页动画", selection: $settings.pageTurn) {
                        ForEach(SettingsStore.PageTurn.allCases, id: \.self) { turn in
                            Text(turn.displayName).tag(turn)
                        }
                    }
                    Toggle("段落缩进", isOn: $settings.textIndent)
                    Toggle("显示进度", isOn: $settings.showProgress)
                }

                Section("漫画") {
                    Toggle("图片适应宽度", isOn: $settings.comicFitWidth)
                }

                Section("外观") {
                    Picker("主题", selection: $settings.appearance) {
                        ForEach(SettingsStore.Appearance.allCases, id: \.self) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                }
            }
            .navigationTitle("排版设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
