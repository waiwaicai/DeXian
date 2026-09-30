import SwiftUI

/// 正文文本归一化：滚动模式与翻页模式必须用同一份结果，
/// 否则同一章在两种模式下的分段与缩进会不一致。
enum ReaderTextFormatting {
    /// 把原始正文转成展示用文本：丢弃空行，段首按需缩进两格
    static func displayText(_ content: String, indent: Bool) -> String {
        guard !content.isEmpty else { return "" }
        var lines: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lines.append(indent ? "　　" + trimmed : trimmed)
        }
        return lines.joined(separator: "\n")
    }
}

/// 阅读页统一的尺寸常量
enum ReaderMetrics {
    /// 正文顶部额外让开的距离。
    ///
    /// 旧值是 52，加上安全区（实测 59）后正文从 118pt 处才开始，
    /// 而底部又预留 92 —— 一屏 874pt 里有 262pt（30%）永远是空白，
    /// 用户看到的就是「排版没有铺满全屏」。
    ///
    /// 顶部与底部工具条都是**浮层**（.overlay + 自动隐藏），不参与布局，
    /// 所以正文没必要按工具条的完整高度长期让位。这里只留一点余量，
    /// 让正文基本铺满整屏。
    ///
    /// 不能改成「工具条显示时多留、隐藏时少留」：那会让每次收展工具条
    /// 都触发重新分页，正文行数和字号视觉上会跟着跳 —— 正是用户反复
    /// 反馈的「弹出顶部框后字的排序还会变大小」。
    static let topInset: CGFloat = 10
    /// 正文底部让开的距离：够让最后一行不被底栏压住即可（约一行字高）
    static let bottomInset: CGFloat = 40

    /// 视频播放页专用的上下预留。
    ///
    /// 不能跟着正文一起收紧：视频画面是铺满宽度的实心矩形，顶栏浮层
    /// 一旦压上去就会盖住画面上沿，底栏会盖住进度条。
    /// 正文是字，被浮层遮住一点无伤大雅，视频不行。
    static let videoTopInset: CGFloat = 52
    static let videoBottomInset: CGFloat = 92
}

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
    /// 是否切到听书界面（文本书源也可用系统语音朗读）
    @State private var audioMode = false

    init(book: ShelfBook, source: BookSource?, shelf: ShelfStore) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(book: book, source: source, shelf: shelf))
    }

    var body: some View {
        ZStack {
            readerBackground

            // 正文容器自带轻点分区手势（simultaneousGesture），
            // 不再叠一层 Color.clear 的 tapLayer ——
            // 那一层铺满全屏、吃掉了所有拖动事件，
            // 表现就是「页面无法上下滑动」。
            GeometryReader { geometry in
                tapHandling(contentArea, geometry: geometry)
            }
        }
        // 顶部与底部工具条都改成自绘浮层。
        //
        // 关键点：不再用系统导航栏显示/隐藏来控制顶部条。
        // 导航栏显隐会改变顶部安全区，正文被迫重排 ——
        // 用户看到的就是「一弹出顶部框，字的排序和大小全变了」。
        // 自绘浮层不参与布局，显隐都不影响正文。
        // 顶部与底部拆成两个「贴边」浮层，而不是一个铺满全屏的 VStack。
        // 后者中间那个 Spacer 会占满整块屏幕，读者在正文上拖动时
        // 命中判定落到浮层上，滚动直接被吃掉 ——
        // 这正是「点开小说页面无法上下滑动」的成因。
        // 拆开后浮层只剩上下两条，中间区域完全交还给正文。
        // 视频全屏时由播放器接管整屏，外层浮层必须让位，
        // 否则顶栏会横压在视频上、底栏会盖住进度条。
        .overlay(alignment: .top) { if !videoIsFullScreen { topChrome } }
        .overlay(alignment: .bottom) { if !videoIsFullScreen { bottomChrome } }
        .animation(.easeOut(duration: 0.2), value: showChrome)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // 工具条自动隐藏：显示后 4 秒无操作自动收起
        .task(id: showChrome) {
            guard showChrome else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showChrome = false }
        }
        .task {
            await viewModel.loadTocIfNeeded()
            // 不能要求 chapters 非空：漫画源没有目录时，
            // loadTocIfNeeded() 会走单章兜底，此时目录仍为空、
            // 但正文/图片其实已经取回来了。旧条件会把这种情况挡在门外，
            // 表现就是封面一直转圈、内容永远出不来。
            if viewModel.content.isEmpty, viewModel.images.isEmpty {
                await viewModel.loadContent(index: viewModel.currentIndex)
            }
            if !viewModel.isAudio {
                viewModel.preloadNeighbors()
            }
        }
        .onChange(of: viewModel.currentIndex) { _ in
            withAnimation(.easeOut(duration: 0.18)) { showChrome = false }
        }
        .sheet(isPresented: $showCatalog) {
            CatalogView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet()
        }
        // 刻意不用 .statusBar(hidden:)：状态栏显隐会改变顶部安全区，
        // 正文会被迫重排 —— 那正是用户反馈的「字排着排着就变了」。
    }

    /// 给滚动 / 漫画 / 听书模式挂轻点分区手势。
    ///
    /// 翻页模式（PagedReaderView）自己处理左右轻点翻页，
    /// 这里必须跳过，否则两套手势会同时触发。
    /// 用 simultaneousGesture 而不是叠一层 Color.clear：
    /// 那种铺满全屏的透明层会吃掉拖动事件，页面就没法上下滑动了。
    @ViewBuilder
    private func tapHandling<C: View>(_ content: C, geometry: GeometryProxy) -> some View {
        if isPagedSurface {
            content
        } else {
            content.simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handleTap(
                            x: value.location.x / max(geometry.size.width, 1),
                            y: value.location.y / max(geometry.size.height, 1)
                        )
                    }
            )
        }
    }

    /// 漫画模式下的极简状态条
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

    // MARK: 轻点分区

    /// 轻点分区：左 30% 上一章 / 上一页，右 30% 下一章 / 下一页，
    /// 中间 40% 收展工具条。
    private func handleTap(x: CGFloat, y: CGFloat) {
        // 听书与漫画都是连续滚动，误触翻章体验很差，只收展工具条
        if isAudioSurface || isVideoSurface || viewModel.isComic {
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

    /// 影视 / 短剧源：整屏交给播放器，不参与文本排版
    private var isVideoSurface: Bool { viewModel.isVideo }

    /// 视频全屏中：外层浮层让位，整屏都给播放器
    private var videoIsFullScreen: Bool { viewModel.isVideo && viewModel.isVideoFullScreen }

    /// 是否处于「整页翻页」阅读模式
    private var isPagedSurface: Bool {
        !isAudioSurface && !isVideoSurface && !viewModel.isComic && settings.pageTurn != .scroll
    }

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
                && viewModel.images.isEmpty && viewModel.audioUrl.isEmpty
                && viewModel.videoUrl.isEmpty:
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
                if isVideoSurface {
                    VideoPlayerView(viewModel: viewModel)
                } else if isAudioSurface {
                    AudioReaderView(viewModel: viewModel)
                } else if viewModel.isComic {
                    ComicReaderView(
                        images: viewModel.images,
                        fitWidth: settings.comicFitWidth,
                        referer: viewModel.currentChapter?.url ?? "",
                        sourceKey: viewModel.book.origin
                    )
                    // 仅换章时重建（用于重置已放行页数）；
                    // 不再用全局令牌，避免每次翻章都重建整个阅读视图造成排版跳动。
                    .id(viewModel.currentIndex)
                } else if settings.pageTurn == .scroll {
                    // 滚动模式：连续长文
                    TextReaderView(viewModel: viewModel)
                } else {
                    // 翻页模式：按屏幕切页，支持覆盖 / 平移 / 无动画
                    PagedReaderView(viewModel: viewModel, showChrome: $showChrome)
                        .id(viewModel.currentIndex)
                }
            }
        }
    }

    // MARK: 自绘浮层（顶部 + 底部）

    @ViewBuilder
    private var topChrome: some View {
        if showChrome { topBar }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if showChrome {
                cacheProgressBar
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if viewModel.isComic, !viewModel.images.isEmpty {
                comicBadge
            }
        }
    }

    /// 自绘顶栏：返回 + 章节标题 + 进度 + 更多菜单。
    /// 不占用布局空间，因此显隐不会让正文重排。
    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(chromeTextColor)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 1) {
                Text(viewModel.currentChapter?.title ?? viewModel.book.name)
                    .font(.themeCaptionBold)
                    .foregroundStyle(chromeTextColor)
                    .lineLimit(1)
                if settings.showProgress {
                    Text(viewModel.progressText)
                        .font(.themeTiny)
                        .foregroundStyle(chromeTextColor.opacity(0.65))
                }
            }
            .frame(maxWidth: .infinity)

            readerMenu
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var readerMenu: some View {
        Menu {
            Button {
                showCatalog = true
            } label: { Label("目录", systemImage: "list.bullet") }

            Button {
                showSettings = true
            } label: { Label("排版设置", systemImage: "textformat.size") }

            // 影视源没有正文，听书开关对它没有意义
            if !viewModel.isAudio && !isVideoSurface {
                Button {
                    audioMode.toggle()
                } label: {
                    Label(audioMode ? "退出听书" : "听书", systemImage: audioMode ? "book" : "headphones")
                }
            }

            Button {
                Task { await viewModel.cacheAll() }
            } label: {
                Label(viewModel.cacheAllText,
                      systemImage: viewModel.isCachingAll ? "stop.circle" : "arrow.down.circle")
            }
            .disabled(viewModel.chapters.isEmpty || viewModel.isAudio || isVideoSurface)

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
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(chromeTextColor)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
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
        HStack(spacing: Theme.Spacing.sm) {
            chromeButton("目录", systemImage: "list.bullet") { showCatalog = true }

            Spacer(minLength: Theme.Spacing.xs)

            chromeButton("上一章", systemImage: "chevron.left") {
                Task { await viewModel.goPrevious() }
            }
            .disabled(viewModel.currentIndex == 0)

            chromeButton("下一章", systemImage: "chevron.right") {
                Task { await viewModel.goNext() }
            }
            .disabled(viewModel.currentIndex >= viewModel.chapters.count - 1)

            Spacer(minLength: Theme.Spacing.xs)

            if viewModel.isAudio {
                chromeButton("隐藏", systemImage: "chevron.down") { showChrome = false }
            } else if audioMode {
                chromeButton("退出听书", systemImage: "text.alignleft") { audioMode = false }
            } else {
                chromeButton("听书", systemImage: "headphones") { audioMode.toggle() }

                chromeButton("界面", systemImage: "textformat.size") { showSettings = true }
            }
        }
        // 工具条必须能收进屏幕：5 个按钮在窄屏（SE 320pt）上按固定宽
        // 会算出比屏幕还宽的固有尺寸，把整个容器撑大，正文随之变宽位移。
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm + 2)
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
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            // 用较小下限而非固定 52：由父级分配空间，绝不反过来撑宽父级。
            .frame(minWidth: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 文字阅读（滚动）

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
                        // 整章交给同一个 TextKit 视图渲染。
                        //
                        // 不用逐段 `Text` 拼 VStack：那样段落间距走的是
                        // VStack 的 spacing，而两端对齐在 SwiftUI 里根本没有，
                        // 右边界会参差不齐（实测右余量在 28~38pt 抖动），
                        // 看起来就是「没铺满、整体偏左」。
                        // TextKit 一次排版整章，段间距与两端对齐都真实生效，
                        // 且与 PageSplitter 的度量同源。
                        ReaderTextView(
                            text: displayText,
                            font: bodyFont,
                            color: textUIColor,
                            lineSpacing: CGFloat(settings.lineSpacing),
                            paragraphSpacing: CGFloat(settings.paragraphSpacing),
                            selectable: true,
                            justified: true
                        )
                        .id("content")
                    }

                    chapterFooter
                }
                .padding(.horizontal, Theme.Spacing.xl)
                // 顶部与底部都留出自绘工具条的高度，展开时不会盖住正文
                .padding(.top, ReaderMetrics.topInset)
                .padding(.bottom, ReaderMetrics.bottomInset)
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

    /// 展示用正文：空行丢弃，段首按设置决定是否缩进两格
    private var displayText: String {
        ReaderTextFormatting.displayText(viewModel.content, indent: settings.textIndent)
    }

    /// 正文字体。
    ///
    /// 与翻页模式共用 `PageSplitter.uiFont`：两种模式必须拿同一个 UIFont，
    /// 否则「等宽」这类字体在两种模式下度量不同，同一章换模式后行宽会变。
    private var bodyFont: UIFont {
        PageSplitter.uiFont(family: settings.fontFamily, size: settings.fontSize)
    }

    private var textUIColor: UIColor {
        UIColor(rgb: readerColorValue)
    }

    /// 当前生效的正文颜色值（与 ReaderView 的背景选择保持一致）
    private var readerColorValue: UInt32 {
        if settings.readerFollowsSystem {
            return colorScheme == .dark ? 0xC9CDD4 : 0x2A2D33
        }
        return settings.readerTheme.textColor
    }

    /// 正文颜色：与 ReaderView 的背景选择保持一致
    private var textColor: Color {
        if settings.readerFollowsSystem {
            return colorScheme == .dark ? Color(hex: 0xC9CDD4) : Color(hex: 0x2A2D33)
        }
        return Color(hex: settings.readerTheme.textColor)
    }
}

// MARK: - 文字阅读（翻页）

/// 整页翻页阅读器。
///
/// 覆盖 / 平移 / 无动画三种模式在这里真正生效：
/// 先用 PageSplitter 按屏幕尺寸把本章切页，再按所选模式做转场。
struct PagedReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Binding var showChrome: Bool
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var pages: [String] = []
    @State private var pageIndex = 0
    /// 是否正在分页：分页是异步的，期间不能误报「本章暂无正文」
    @State private var isPaginating = false
    /// 翻页方向：1 前进、-1 后退，用于决定转场方向
    @State private var direction = 1
    @State private var size: CGSize = .zero

    /// 排版相关参数，任一变化都要重新分页
    private struct LayoutKey: Equatable {
        var width: Int
        var height: Int
        var fontSize: Int
        var lineSpacing: Int
        var paragraphSpacing: Int
        var family: String
        var indent: Bool
        /// 底栏显隐会影响可用高度，必须参与比较，否则开关后不重排
        var showFooter: Bool
        /// 正文长度：内容一变就要重新分页（用长度而不是全文，避免每帧重排）
        var contentLength: Int
    }

    /// 排版 key。
    ///
    /// 注意：这里刻意只用尺寸、字号等「便宜」的参数，
    /// 正文本身用 `viewModel.content.count` 参与比较 ——
    /// 直接对整章做格式化会在这个属性被读取时重排全文，
    /// 而这个属性每帧都会被 SwiftUI 求值。
    private var layoutKey: LayoutKey {
        LayoutKey(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            fontSize: Int(settings.fontSize.rounded()),
            lineSpacing: Int(settings.lineSpacing.rounded()),
            paragraphSpacing: Int(settings.paragraphSpacing.rounded()),
            family: settings.fontFamily,
            indent: settings.textIndent,
            showFooter: settings.showPageFooter,
            contentLength: viewModel.content.count
        )
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                pageBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // 底部翻页条默认不显示：正文之外再压一条工具栏
                // 既占高度又抢注意力，翻页用左右轻点 / 横滑就够了。
                // 想看页码的话可以在「排版设置」里打开。
                if settings.showPageFooter {
                    pageFooter
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, ReaderMetrics.topInset)
            .padding(.bottom, ReaderMetrics.bottomInset)
            .onAppear { size = geometry.size }
            .onChange(of: geometry.size) { value in size = value }
        }
        .task(id: layoutKey) { await repaginate() }
        .contentShape(Rectangle())
        // 翻页手势统一走 simultaneousGesture。
        //
        // 原先横滑用 .gesture(...)：它在 SwiftUI 里是**高优先级**手势，
        // 会把轻点与系统返回手势一起压掉，并且和上下滚动互相抢事件，
        // 结果就是「翻页动画都不能动、页面也滑不动」。
        // 现在横滑与轻点都作为并行手势，只判断位移方向，互不吞事件：
        // 横向位移足够就翻页，纵向为主就交还给外层滚动。
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // 纵向为主：这次拖动是滚动正文，不要当成翻页
                    guard abs(dx) > abs(dy) * 1.6, abs(dx) > 48 else { return }
                    if dx < 0 { turnForward() } else { turnBackward() }
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    let ratio = value.location.x / max(size.width, 1)
                    if ratio < 0.3 {
                        turnBackward()
                    } else if ratio > 0.7 {
                        turnForward()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { showChrome.toggle() }
                    }
                }
        )
    }

    @ViewBuilder
    private var pageBody: some View {
        if viewModel.isLoadingContent, viewModel.content.isEmpty {
            VStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("正在加载正文")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pages.isEmpty, isPaginating {
            VStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("正在排版")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pages.isEmpty {
            EmptyStateView(
                systemImage: "doc.text",
                title: "本章暂无正文",
                message: "可能是付费章节，或书源规则需要更新。"
            )
        } else {
            let current = pages.indices.contains(pageIndex) ? pages[pageIndex] : ""
            // 与分页测量同源：同一个 UIFont、同一份段落样式（含两端对齐）。
            // 用 SwiftUI 的 Text 会缺少两端对齐，且它与 PageSplitter 的
            // TextKit 度量存在差异，每页末尾的字会被裁掉。
            ReaderTextView(
                text: current,
                font: PageSplitter.uiFont(family: settings.fontFamily, size: settings.fontSize),
                color: UIColor(rgb: readerColorValue),
                lineSpacing: CGFloat(settings.lineSpacing),
                paragraphSpacing: CGFloat(settings.paragraphSpacing),
                // 翻页模式禁用选中：长按选中会与左右轻点翻页抢手势
                selectable: false,
                justified: true
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // .id 让每一页成为独立视图，转场才能按方向移动
                .id(pageIndex)
                .transition(pageTransition)
        }
    }

    /// 三种翻页动画
    private var pageTransition: AnyTransition {
        switch settings.pageTurn {
        case .cover:
            // 覆盖：新页从右侧盖上来，旧页留在原地
            return .asymmetric(
                insertion: .move(edge: direction > 0 ? .trailing : .leading),
                removal: .opacity
            )
        case .slide:
            // 平移：新旧页一起横向移动
            return .asymmetric(
                insertion: .move(edge: direction > 0 ? .trailing : .leading),
                removal: .move(edge: direction > 0 ? .leading : .trailing)
            )
        case .none, .scroll:
            return .identity
        }
    }

    private var pageFooter: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                turnBackward()
            } label: {
                Label("上一页", systemImage: "chevron.left")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.Palette.brand)
            }
            .buttonStyle(.plain)
            .disabled(pages.isEmpty || (pageIndex == 0 && viewModel.currentIndex == 0))

            Spacer(minLength: 0)

            Text(String(min(pageIndex + 1, max(pages.count, 1))) + "/" + String(max(pages.count, 1))
                 + " · " + viewModel.progressText)
                .font(.themeTiny)
                .foregroundStyle(Theme.ColorToken.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            Button {
                turnForward()
            } label: {
                Label("下一页", systemImage: "chevron.right")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.Palette.brand)
            }
            .buttonStyle(.plain)
            .disabled(pages.isEmpty
                      || (pageIndex >= pages.count - 1
                          && viewModel.currentIndex >= viewModel.chapters.count - 1))
        }
        .padding(.top, Theme.Spacing.sm)
    }

    // MARK: 分页与翻页

    /// 重新分页：计算放到后台线程，避免长章卡住主线程
    private func repaginate() async {
        // 与滚动模式共用同一份格式化结果，两种模式排版才一致
        let content = ReaderTextFormatting.displayText(
            viewModel.content, indent: settings.textIndent
        )
        guard !content.isEmpty else {
            pages = []
            pageIndex = 0
            isPaginating = false
            return
        }
        // 尺寸还没测量好：保持现状，等下一次尺寸回调再算
        guard size.width > 40, size.height > 80 else { return }

        // 可用高度必须与**实际渲染**的布局完全对齐，多扣一分就会
        // 「每页少排一行、正文停在半空」。
        //
        // 正文外层只加了三种内边距：.horizontal(xl)、.top(topInset)、
        // .bottom(bottomInset)；底栏显示时再占掉它自己那一行。
        // 这里就按这三项加底栏高度计算，不再额外多扣 ——
        // 旧实现多减了 xl+lg 共 36pt，正好是一行字的高度。
        let footerHeight: CGFloat = settings.showPageFooter ? 34 : 0
        let reserved: CGFloat = ReaderMetrics.topInset
            + ReaderMetrics.bottomInset
            + footerHeight
        let layout = PageSplitter.Layout(
            font: PageSplitter.uiFont(family: settings.fontFamily, size: settings.fontSize),
            lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing,
            indent: settings.textIndent,
            height: max(120, size.height - reserved),
            width: max(120, size.width - Theme.Spacing.xl * 2)
        )
        // 段首已经带了「　　」，排版层不能再缩进一次
        var adjusted = layout
        adjusted.indent = false

        isPaginating = true
        let result = await Background.run {
            PageSplitter.paginate(text: content, layout: adjusted)
        }
        // 已被新一次分页取代：不要写回旧结果
        guard !Task.isCancelled else { return }
        pages = result
        isPaginating = false
        pageIndex = min(pageIndex, max(0, result.count - 1))
    }

    private func turnForward() {
        // 还没分好页（或本章没有正文）：什么也不做，避免误跳章
        guard !pages.isEmpty, !isPaginating else { return }
        if pageIndex < pages.count - 1 {
            direction = 1
            advance { pageIndex += 1 }
        } else {
            // 最后一页：进入下一章，从第 1 页开始
            pageIndex = 0
            Task { await viewModel.goNext() }
        }
    }

    private func turnBackward() {
        guard !pages.isEmpty, !isPaginating else { return }
        if pageIndex > 0 {
            direction = -1
            advance { pageIndex -= 1 }
        } else {
            Task { await viewModel.goPrevious() }
        }
    }

    /// 无动画模式下直接改状态，其余模式包一层动画。
    ///
    /// 时长放到 0.28s 并把曲线换成 easeInOut：0.22s 的 easeOut
    /// 太短，页面还没移出屏幕就结束了，肉眼看着像「动画没生效」。
    private func advance(_ change: () -> Void) {
        if settings.pageTurn == .none {
            change()
        } else {
            withAnimation(.easeInOut(duration: 0.28)) { change() }
        }
    }

    /// 当前生效的正文颜色值
    private var readerColorValue: UInt32 {
        if settings.readerFollowsSystem {
            return colorScheme == .dark ? 0xC9CDD4 : 0x2A2D33
        }
        return settings.readerTheme.textColor
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
        let screen = UIScreen.main
        let scale = screen.scale > 0 ? screen.scale : 2
        let maxPixel = max(screen.bounds.width, screen.bounds.height) * scale
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

    /// 预览用的示例段落。
    ///
    /// 刻意用两段：段落间距是「段与段之间」的距离，
    /// 只有一段文字时这个设置改了也看不出任何变化。
    private var previewParagraphs: [String] {
        [
            "得闲 · 示例正文 Aa 123",
            "调整字号、行距、段落间距与字体，这里会同步变化。"
        ]
    }

    /// 实时预览卡片。
    ///
    /// 直接复用阅读页的渲染组件 `ReaderTextView`：同一个 UIFont、
    /// 同一份段落样式、同样的两端对齐与段间距。
    ///
    /// 排版参数必须逐项与真机渲染对齐，预览才有参考价值 ——
    /// 旧预览是 SwiftUI 的 `Text` 拼 VStack，既没有两端对齐，
    /// 段间距也走的是 VStack spacing，与正文的 TextKit 排版并不一致：
    /// 用户按预览调好样式，进正文看到的却是另一副样子。
    /// （更早的版本预览还是单行文本，改行距 / 段距时它纹丝不动。）
    private var previewCard: some View {
        ReaderTextView(
            text: previewParagraphs
                .map { settings.textIndent ? "　　" + $0 : $0 }
                .joined(separator: "\n"),
            font: previewUIFont,
            color: previewTextUIColor,
            lineSpacing: CGFloat(settings.lineSpacing),
            paragraphSpacing: CGFloat(settings.paragraphSpacing),
            selectable: false,
            justified: true
        )
        .frame(minHeight: 72)
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(previewBackground)
        )
        // 预览是展示用的，不要让它吃手势 / 被选中
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: settings.fontSize)
        .animation(.easeOut(duration: 0.12), value: settings.lineSpacing)
        .animation(.easeOut(duration: 0.12), value: settings.paragraphSpacing)
        .animation(.easeOut(duration: 0.12), value: settings.fontFamily)
        .animation(.easeOut(duration: 0.12), value: settings.textIndent)
    }

    /// 预览字体与阅读页同源。
    ///
    /// 两种阅读模式现在统一用 `PageSplitter.uiFont`（TextKit 渲染），
    /// 预览也必须用它，否则「等宽」这类字体在预览与正文里度量不同，
    /// 用户会以为设置没生效。
    private var previewUIFont: UIFont {
        PageSplitter.uiFont(family: settings.fontFamily, size: settings.fontSize)
    }

    private var previewTextUIColor: UIColor {
        settings.readerFollowsSystem
            ? UIColor(rgb: 0x2A2D33)
            : UIColor(rgb: settings.readerTheme.textColor)
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
                // 预览放在最前面：调下面的滑杆时它一直在视野里，
                // 改动能立刻看到，不用上下翻。
                Section("预览") {
                    previewCard
                        .padding(.vertical, Theme.Spacing.xs)
                }

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
                }

                Section("字体与行距") {
                    Picker("字体", selection: $settings.fontFamily) {
                        ForEach(SettingsStore.fontFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Text("行距")
                        Slider(value: $settings.lineSpacing, in: 0...24, step: 1)
                        Text(String(Int(settings.lineSpacing)))
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                    }

                    // 段落间距：长文阅读时拉开段落更省眼
                    HStack {
                        Text("段落间距")
                        Slider(value: $settings.paragraphSpacing, in: 0...30, step: 2)
                        Text(String(Int(settings.paragraphSpacing)))
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                    }

                    Toggle("段落缩进", isOn: $settings.textIndent)
                }

                Section("翻页") {
                    Picker("翻页动画", selection: $settings.pageTurn) {
                        ForEach(SettingsStore.PageTurn.allCases, id: \.self) { turn in
                            Text(turn.displayName).tag(turn)
                        }
                    }
                    Toggle("显示顶部进度", isOn: $settings.showProgress)
                    Toggle("显示底部翻页条", isOn: $settings.showPageFooter)
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
