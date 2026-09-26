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

            // 轻点显示菜单，再次轻点隐藏；双击直接翻到下一章
            tapLayer

            if showChrome {
                chromeOverlay
            } else if viewModel.isComic, !viewModel.images.isEmpty {
                comicBadge
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
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

    private var tapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !showChrome, !isAudioSurface else { return }
                Task { await viewModel.goNext() }
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
            }
            .ignoresSafeArea(edges: .bottom)
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
                        referer: viewModel.currentChapter?.url ?? ""
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

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(viewModel.currentChapter?.title ?? viewModel.book.name)
                .font(.themeHeadline)
                .foregroundStyle(chromeTextColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Spacing.sm) {
                Text(viewModel.book.name)
                    .font(.themeCaption)
                    .foregroundStyle(chromeTextColor.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                if settings.showProgress {
                    Text(viewModel.progressText)
                        .font(.themeCaptionBold)
                        .foregroundStyle(Theme.Palette.brand)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.md)
        .background(.ultraThinMaterial)
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
                        Text(displayContent)
                            .font(settings.readingFont)
                            .lineSpacing(settings.lineSpacing)
                            .foregroundStyle(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 段落缩进与首行处理
    private var displayContent: String {
        let raw = viewModel.content
        guard settings.textIndent else { return raw }
        return raw
            .components(separatedBy: "\n")
            .map { line -> String in
                let value = line.trimmingCharacters(in: .whitespaces)
                if value.isEmpty { return "" }
                return "　　" + value
            }
            .joined(separator: "\n")
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

    var body: some View {
        if images.isEmpty {
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: "本章没有图片",
                message: "该章节未解析到图片，可能是付费章节或书源规则需要更新。"
            )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, url in
                        ComicPageView(url: url, fitWidth: fitWidth, referer: referer)
                    }
                }
                .padding(.top, Theme.Spacing.lg)
            }
        }
    }
}

/// 单页漫画（等比展示、可加载失败重试）
struct ComicPageView: View {
    let url: String
    var fitWidth: Bool

    @State private var image: UIImage?
    @State private var failed = false
    /// 已尝试次数：大于 0 时给请求加时间戳，绕过 URLCache 拿到真实结果
    @State private var attempt = 0
    /// 正文所在页地址，作为图片请求的 Referer（多数图站会校验）
    var referer: String = ""

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
                    Button("重试") {
                        failed = false
                        attempt += 1
                        Task { await load() }
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
        .task(id: url) {
            await load()
        }
    }

    /// 重试时附加时间戳，避免命中失败的缓存
    private var requestURL: String {
        guard attempt > 0 else { return url }
        let separator = url.contains("?") ? "&" : "?"
        return url + separator + "_r=" + String(attempt)
    }

    private func load() async {
        guard image == nil else { return }
        // 只在首次加载时读缓存，重试一律走网络
        if attempt == 0, let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let data = try await HTTPClient.shared.data(
                urlString: requestURL,
                headers: ["Referer": referer.isEmpty ? url : referer]
            )
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            ImageCache.shared.store(decoded, for: url)
            image = decoded
        } catch {
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
                    Button {
                        ascending.toggle()
                    } label: {
                        Image(systemName: ascending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
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
                        Text("系统").tag("系统")
                        Text("宋体").tag("宋体")
                        Text("圆体").tag("圆体")
                    }
                    .pickerStyle(.segmented)
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
