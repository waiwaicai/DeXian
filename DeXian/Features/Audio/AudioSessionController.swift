import SwiftUI
import Combine

/// 听书会话控制器：统一封装「系统语音朗读」与「音频直链播放」两种模式。
///
/// 文本书源使用语音合成，音频书源（bookSourceType = 1）使用播放器，
/// 界面只需关心 isPlaying / progress / error 三个状态。
final class AudioSessionController: ObservableObject {

    enum Mode {
        /// 系统语音朗读（文本书源）
        case speech
        /// 播放音频直链（音频书源）
        case player
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?
    /// 暂停中，点播放应继续而不是从头开始
    @Published private(set) var isPaused = false
    /// 当前模式，界面据此决定是显示语速还是跳转按钮
    @Published private(set) var mode: Mode = .speech

    /// 一章读完
    var onChapterFinish: (() -> Void)?
    /// 连播开关。由界面在设置变化时同步进来，
    /// 读完一章时按当前值决定是否继续（不直接用闭包读设置，避免线程隔离问题）。
    var continuousEnabled = true

    private let autoReader = AutoReader()
    private let playback = AudioPlaybackController()

    init() {
        autoReader.onProgress = { [weak self] value, _ in
            Task { @MainActor in self?.progress = value }
        }
        autoReader.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.progress = 1
                self.finishChapter()
            }
        }
        autoReader.onError = { [weak self] message in
            Task { @MainActor in
                self?.error = message
                self?.isPlaying = false
            }
        }

        playback.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.progress = 1
                self.finishChapter()
            }
        }
        playback.onError = { [weak self] message in
            Task { @MainActor in
                self?.error = message
                self?.isPlaying = false
            }
        }
        playback.onLoadingChanged = { [weak self] loading in
            Task { @MainActor in self?.isLoading = loading }
        }
    }

    // MARK: 播放

    /// 朗读一段文字
    func speak(_ text: String, wordsPerMinute: Double) {
        mode = .speech
        error = nil
        progress = 0
        isLoading = false
        autoReader.speak(text, wordsPerMinute: wordsPerMinute)
        isPlaying = true
        isPaused = false
    }

    /// 播放一个音频地址
    func play(url: String) {
        mode = .player
        error = nil
        progress = 0
        playback.play(urlString: url)
        isPlaying = true
        isPaused = false
    }

    func pause() {
        switch mode {
        case .speech: autoReader.pause()
        case .player: playback.pause()
        }
        isPlaying = false
        isPaused = true
        refreshPlayerProgress()
    }

    func resume() {
        switch mode {
        case .speech: autoReader.resume()
        case .player: playback.resume()
        }
        isPlaying = true
        isPaused = false
    }

    func stop() {
        autoReader.stop()
        playback.stop()
        isPlaying = false
        isPaused = false
    }

    /// 一章结束：只有开启连播才通知界面切下一章
    private func finishChapter() {
        guard continuousEnabled else { return }
        onChapterFinish?()
    }

    /// 播放中刷新进度（界面用定时器调用）
    func refreshPlayerProgress() {
        guard mode == .player, let value = playback.progress else { return }
        progress = value
    }
}
