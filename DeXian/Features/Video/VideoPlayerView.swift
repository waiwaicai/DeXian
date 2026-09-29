import SwiftUI
import AVKit

/// 影视 / 短剧播放界面（自绘控制层）。
///
/// 为什么不用 AVKit 的 `VideoPlayer`：
/// 它只提供播放 / 暂停、进度、全屏三个系统控件，
/// 而影视源用户的默认预期是「左右滑快进、左竖滑亮度、右竖滑音量」这一套
/// 主流播放器手势。系统控件无法扩展出这些手势，所以控制层自绘，
/// 播放内核仍然交给 AVPlayer。
struct VideoPlayerView: View {
    @ObservedObject var viewModel: ReaderViewModel

    @StateObject private var controller = VideoPlaybackController()

    /// 全屏状态放进 viewModel：阅读页要据此隐藏自己的顶 / 底浮层。
    /// 用计算属性包一层，读写点保持简短。
    private var isFullScreen: Bool { viewModel.isVideoFullScreen }
    /// 控制层显隐。播放中自动隐藏，点一下唤出。
    @State private var showControls = true
    /// 手势进行中的浮层提示（快进 / 亮度 / 音量）
    @State private var hud: HUD?
    /// 手势开始时的基准值：亮度、音量、进度都要从「按下那一刻」算偏移量
    @State private var gestureStart: GestureStart = GestureStart()
    @State private var hideTask: Task<Void, Never>?

    /// 手势浮层类型
    private enum HUD: Equatable {
        case seek(seconds: Double)
        case brightness(Double)
        case volume(Double)

        var icon: String {
            switch self {
            case .seek(let value): return value >= 0 ? "goforward" : "gobackward"
            case .brightness: return "sun.max.fill"
            case .volume: return "speaker.wave.2.fill"
            }
        }

        var text: String {
            switch self {
            case .seek(let value):
                let sign = value >= 0 ? "+" : "-"
                return sign + String(Int(abs(value))) + " 秒"
            case .brightness(let value), .volume(let value):
                return String(Int((value * 100).rounded())) + "%"
            }
        }

        var progress: Double? {
            switch self {
            case .seek: return nil
            case .brightness(let value), .volume(let value): return min(1, max(0, value))
            }
        }
    }

    private struct GestureStart {
        var brightness: Double = 0
        var volume: Double = 0
        var position: Double = 0
    }

    var body: some View {
        Group {
            if isFullScreen {
                playerSurface(immersive: true)
                    .ignoresSafeArea()
                    // 隐藏系统状态栏（iOS 16 起用 .statusBar(hidden:)，
                    // 早前的 .statusBarHidden() 已废弃）
                    .statusBar(hidden: true)
            } else {
                VStack(spacing: 0) {
                    playerSurface(immersive: false)
                        .frame(height: playerHeight)
                    infoArea
                    Spacer(minLength: 0)
                }
                .padding(.top, ReaderMetrics.topInset)
                .padding(.bottom, ReaderMetrics.bottomInset)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isFullScreen)
        .task {
            if viewModel.chapters.isEmpty {
                await viewModel.loadTocIfNeeded()
            }
            if viewModel.videoUrl.isEmpty {
                await viewModel.loadVideo()
            }
            scheduleHideControls()
        }
        // 换集：currentIndex 变化时重新解析直链
        .onChange(of: viewModel.currentIndex) { _ in
            Task { await viewModel.loadVideo() }
        }
        .onChange(of: viewModel.videoUrl) { url in
            guard !url.isEmpty else { return }
            controller.load(url: url)
            scheduleHideControls()
        }
        // 起播那一刻才真正开始倒计时收控制层：
        // 加载阶段判定会因 isPlaying 仍是 false 而直接跳过，
        // 不补这一次的话控制层会一直挂在那里等用户点。
        .onChange(of: controller.isPlaying) { playing in
            if playing { scheduleHideControls() }
        }
        // 退出页面务必收回横屏许可，否则书架会跟着转
        .onDisappear {
            hideTask?.cancel()
            controller.stop()
            if isFullScreen { DeXianAppDelegate.apply(landscape: false) }
        }
    }

    private var playerHeight: CGFloat {
        // 竖屏内嵌播放区按 16:9 给高度，太小会比控制层还矮
        max(200, UIScreen.main.bounds.width * 9 / 16)
    }

    // MARK: 播放区

    private func playerSurface(immersive: Bool) -> some View {
        ZStack {
            Color.black

            // MPVolumeView 必须挂进视图层级，写系统音量才会生效。
            // 不能给 1x1：尺寸过小时系统不会创建内部的音量滑块，
            // 于是 setVolume 找不到可写的控件。给它正常尺寸再移出屏幕外。
            SystemVolumeView()
                .frame(width: 120, height: 40)
                .offset(x: -10_000)
                .allowsHitTesting(false)

            if controller.hasItem {
                PlayerLayerView(player: controller.player)
            }

            // 手势层：铺满播放区，承载点击与三类滑动
            gestureCatcher

            if viewModel.isLoadingContent || (controller.isBuffering && controller.hasItem) {
                ProgressView().tint(.white).scaleEffect(1.2)
            } else if !controller.hasItem {
                unavailablePlaceholder
            }

            if let hud { hudView(hud) }

            if showControls {
                controlsOverlay(immersive: immersive)
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    private var unavailablePlaceholder: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "play.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text(viewModel.isLoadingContent ? "正在解析播放地址" : "这一集没有解析到播放地址")
                .font(.themeCaption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            if !viewModel.isLoadingContent {
                Button("重试") {
                    Task { await viewModel.loadVideo() }
                }
                .font(.themeCaption)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.18)))
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: 手势

    /// 播放区手势。
    ///
    /// 三块互斥区域，与主流播放器一致：
    /// - 左半屏竖滑 = 亮度；右半屏竖滑 = 音量；
    /// - 任意位置横滑 = 快进 / 快退；
    /// - 轻点 = 显隐控制层。
    ///
    /// 判定顺序上先看「谁的主方向位移更大」，避免斜着滑时亮度与快进同时触发。
    private var gestureCatcher: some View {
        GeometryReader { geo in
            let size = geo.size
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            if gestureStartDirection == nil {
                                beginGesture(at: value.startLocation, in: size)
                            }
                            updateGesture(translation: value.translation, in: size)
                        }
                        .onEnded { _ in
                            endGesture()
                        }
                )
        }
    }

    /// 手势方向判定结果
    private enum DragDirection { case horizontal, verticalLeft, verticalRight }

    private func beginGesture(at point: CGPoint, in size: CGSize) {
        gestureStart = GestureStart(
            brightness: controller.brightness,
            volume: controller.volume,
            position: controller.currentSeconds
        )
        gestureStartDirection = nil
        gestureStartPoint = point
    }

    private func updateGesture(translation: CGSize, in size: CGSize) {
        // 首次移动时锁定方向：横纵位移谁大听谁的
        if gestureStartDirection == nil {
            guard abs(translation.width) > 2 || abs(translation.height) > 2 else { return }
            if abs(translation.width) > abs(translation.height) {
                gestureStartDirection = .horizontal
            } else if gestureStartPoint.x < size.width / 2 {
                gestureStartDirection = .verticalLeft
            } else {
                gestureStartDirection = .verticalRight
            }
        }
        guard let direction = gestureStartDirection else { return }
        cancelHideControls()

        switch direction {
        case .horizontal:
            // 全宽横滑对应 ±120 秒，与主流播放器手感接近
            let delta = Double(translation.width / max(size.width, 1)) * 120
            let target = max(0, gestureStart.position + delta)
            hud = .seek(seconds: delta)
            controller.seek(to: target)

        case .verticalLeft:
            // 半屏高度对应满量程
            let delta = -Double(translation.height / max(size.height, 1))
            let value = min(1, max(0, gestureStart.brightness + delta))
            controller.setBrightness(value)
            hud = .brightness(value)

        case .verticalRight:
            let delta = -Double(translation.height / max(size.height, 1))
            let value = min(1, max(0, gestureStart.volume + delta))
            controller.setVolume(value)
            hud = .volume(value)
        }
    }

    private func endGesture() {
        gestureStartDirection = nil
        hud = nil
        scheduleHideControls()
    }

    @State private var gestureStartDirection: DragDirection?
    @State private var gestureStartPoint: CGPoint = .zero

    private func hudView(_ hud: HUD) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: hud.icon)
                .font(.system(size: 26, weight: .medium))
            Text(hud.text)
                .font(.themeCallout)
                .monospacedDigit()
            if let progress = hud.progress {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(width: 120, height: 4)
                    Capsule().fill(.white).frame(width: max(2, 120 * progress), height: 4)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(.black.opacity(0.55))
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: 控制层

    private func controlsOverlay(immersive: Bool) -> some View {
        VStack {
            HStack {
                Text(viewModel.currentChapter?.displayTitle ?? viewModel.book.name)
                    .font(.themeCallout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    toggleFullScreen()
                } label: {
                    Image(systemName: immersive
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, immersive ? Theme.Spacing.xxl : Theme.Spacing.sm)
            .background(
                LinearGradient(colors: [.black.opacity(0.65), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            )

            Spacer()

            HStack(spacing: Theme.Spacing.lg) {
                Button {
                    if controller.isPlaying { controller.pause() } else { controller.play() }
                    scheduleHideControls()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(spacing: Theme.Spacing.xs) {
                // 进度条可拖动：拖到哪就 seek 到哪
                Slider(
                    value: Binding(
                        get: { controller.duration > 0 ? controller.currentSeconds / controller.duration : 0 },
                        set: { ratio in controller.seek(to: ratio * controller.duration) }
                    ),
                    in: 0...1
                )
                .tint(.white)
                .onEditingChanged { editing in
                    if editing { cancelHideControls() } else { scheduleHideControls() }
                }

                HStack {
                    Text(controller.currentTimeText)
                    Text("/")
                    Text(controller.durationText)
                    Spacer()
                    Button {
                        Task { await viewModel.goPrevious() }
                    } label: {
                        Label("上一集", systemImage: "backward.end.fill")
                            .font(.themeCaption)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await viewModel.goNext() }
                    } label: {
                        Label("下一集", systemImage: "forward.end.fill")
                            .font(.themeCaption)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .font(.themeCaption)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, immersive ? Theme.Spacing.xl : Theme.Spacing.sm)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { showControls.toggle() }
        if showControls { scheduleHideControls() } else { cancelHideControls() }
    }

    /// 播放中 4 秒后自动收起；暂停时保持常显（用户多半正要操作）
    private func scheduleHideControls() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, controller.isPlaying else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { showControls = false }
            }
        }
    }

    private func cancelHideControls() {
        hideTask?.cancel()
        hideTask = nil
        if !showControls {
            withAnimation(.easeOut(duration: 0.18)) { showControls = true }
        }
    }

    private func toggleFullScreen() {
        let next = !viewModel.isVideoFullScreen
        viewModel.isVideoFullScreen = next
        DeXianAppDelegate.apply(landscape: next)
        showControls = true
        scheduleHideControls()
    }

    // MARK: 集数信息

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(viewModel.currentChapter?.displayTitle ?? viewModel.book.name)
                    .font(.themeTitle2)
                    .foregroundStyle(readerTextColor)
                    .lineLimit(2)

                if !viewModel.progressText.isEmpty {
                    Text(viewModel.progressText)
                        .font(.themeCaption)
                        .foregroundStyle(readerSecondaryColor)
                }
            }

            HStack(spacing: Theme.Spacing.md) {
                transportButton(icon: "backward.end.fill", title: "上一集") {
                    Task { await viewModel.goPrevious() }
                }
                transportButton(icon: "forward.end.fill", title: "下一集") {
                    Task { await viewModel.goNext() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
    }

    private func transportButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.themeCallout)
            .foregroundStyle(readerTextColor)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(readerSecondaryColor.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }

    private var readerTextColor: Color { Color(hex: 0xE8EAEE) }
    private var readerSecondaryColor: Color { Color(hex: 0x9AA3AE) }
}
