import SwiftUI

/// 听书界面：语音朗读（文本书源）与音频直链播放（音频书源）共用一套版式。
struct AudioReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var audio = AudioSessionController()
    @State private var timer: Timer?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Theme.Spacing.xl) {
                    cover(size: min(geometry.size.width * 0.58, 240))
                    titleBlock
                    progressBlock
                    transport
                    options
                    statusLine
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xxl + Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl * 2)
            }
        }
        .task {
            audio.continuousEnabled = settings.autoReadContinuous
            audio.onChapterFinish = { [weak viewModel] in
                guard let viewModel else { return }
                Task { await viewModel.goNext() }
            }
            await prepare(autoPlay: true)
        }
        .onChange(of: viewModel.currentIndex) { _ in
            Task { await prepare(autoPlay: settings.autoReadContinuous) }
        }
        .onChange(of: settings.autoReadContinuous) { value in
            audio.continuousEnabled = value
        }
        .onAppear { startTimer() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
            audio.stop()
        }
    }

    // MARK: 封面与标题

    private func cover(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(Theme.ColorToken.surfaceSecondary)

            CoverImage(url: viewModel.book.coverUrl, width: size, height: size * 1.28,
                       cornerRadius: Theme.Radius.lg)

            if audio.isLoading {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(.black.opacity(0.28))
                    .frame(width: size, height: size * 1.28)
                ProgressView().tint(.white)
            }
        }
        .frame(width: size, height: size * 1.28)
        .themeShadow(Theme.Shadow.raised)
    }

    private var titleBlock: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(viewModel.book.name)
                .font(.themeTitle2)
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(viewModel.currentChapter?.title ?? "选择章节开始")
                .font(.themeCaption)
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .lineLimit(1)

            if !viewModel.book.author.isEmpty {
                Text(viewModel.book.author)
                    .font(.themeTiny)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
        }
    }

    // MARK: 进度

    private var progressBlock: some View {
        VStack(spacing: Theme.Spacing.sm) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.ColorToken.surfaceSecondary)
                    Capsule()
                        .fill(Theme.Palette.brand)
                        .frame(width: max(0, min(1, audio.progress)) * geometry.size.width)
                }
            }
            .frame(height: 4)

            HStack {
                Text(viewModel.progressText)
                    .font(.themeTiny)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
                Spacer()
                Text(audio.isPlaying ? "播放中" : (audio.isPaused ? "已暂停" : "未播放"))
                    .font(.themeTiny)
                    .foregroundStyle(audio.isPlaying ? Theme.Palette.success : Theme.ColorToken.textTertiary)
            }
        }
    }

    // MARK: 播放控制

    private var transport: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            circleButton("backward.end.fill", size: 46) {
                Task { await viewModel.goPrevious() }
            }
            .disabled(viewModel.currentIndex == 0)

            Button {
                if audio.isPlaying { audio.pause() } else { Task { await togglePlay() } }
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.Palette.brand)
                        .frame(width: 72, height: 72)
                        .themeShadow(Theme.Shadow.raised)
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            circleButton("forward.end.fill", size: 46) {
                Task { await viewModel.goNext() }
            }
            .disabled(viewModel.currentIndex >= viewModel.chapters.count - 1)
        }
    }

    private func circleButton(_ systemImage: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.ColorToken.surface)
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(Theme.ColorToken.separator, lineWidth: 0.8))
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 选项

    private var options: some View {
        VStack(spacing: Theme.Spacing.md) {
            Toggle(isOn: $settings.autoReadContinuous) {
                Text("读完自动下一章")
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
            }
            .tint(Theme.Palette.brand)

            if audio.mode == .speech {
                VStack(spacing: Theme.Spacing.xs) {
                    HStack {
                        Text("语速")
                            .font(.themeCallout)
                            .foregroundStyle(Theme.ColorToken.textPrimary)
                        Spacer()
                        Text(String(Int(settings.autoReadSpeed)) + " 字/分")
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                    }
                    Slider(value: $settings.autoReadSpeed, in: 180...900, step: 20) { editing in
                        // 拖动过程中不打断朗读，松手后按新语速重新开始本章
                        guard !editing, audio.isPlaying, audio.mode == .speech else { return }
                        audio.speak(viewModel.content, wordsPerMinute: settings.autoReadSpeed)
                    }
                    .tint(Theme.Palette.brand)
                }
            }
        }
        .cardStyle(padding: Theme.Spacing.md)
    }

    private var statusLine: some View {
        Group {
            if let error = audio.error {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .lineLimit(2)
                }
                .font(.themeCaption)
                .foregroundStyle(Theme.Palette.danger)
            } else {
                Text(hint)
                    .font(.themeTiny)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var hint: String {
        if audio.mode == .player { return "音频来自当前书源，加载失败时会自动重试" }
        return "使用系统语音朗读，无需联网即可播放"
    }

    // MARK: 动作

    private func togglePlay() async {
        // 暂停后继续播放，不要从章节开头重来
        if audio.isPaused {
            audio.resume()
            return
        }
        if viewModel.book.type == .audio {
            if viewModel.audioUrl.isEmpty {
                await viewModel.loadAudio()
            }
        } else if viewModel.content.isEmpty {
            await viewModel.loadContent(index: viewModel.currentIndex)
        }
        start()
    }

    /// 准备当前章节：音频源解析直链，文本源加载正文
    private func prepare(autoPlay: Bool) async {
        if viewModel.chapters.isEmpty {
            await viewModel.loadTocIfNeeded()
        }
        guard !viewModel.chapters.isEmpty else { return }
        await viewModel.loadContent(index: viewModel.currentIndex)
        guard autoPlay else { return }
        start()
    }

    private func start() {
        if viewModel.book.type == .audio {
            guard !viewModel.audioUrl.isEmpty else { return }
            audio.play(url: viewModel.audioUrl)
        } else {
            startSpeech()
        }
    }

    private func startSpeech() {
        guard !viewModel.content.isEmpty else { return }
        audio.speak(viewModel.content, wordsPerMinute: settings.autoReadSpeed)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in audio.refreshPlayerProgress() }
        }
    }
}
