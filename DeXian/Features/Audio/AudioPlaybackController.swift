import Foundation
import AVFoundation

/// 音频书源 / 听书播放器：播放书源解析出的音频地址，播完自动进入下一章。
final class AudioPlaybackController: NSObject {

    /// 单章播放结束
    var onFinish: (() -> Void)?
    /// 播放失败
    var onError: ((String) -> Void)?
    /// 加载状态变化
    var onLoadingChanged: ((Bool) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    private(set) var isPlaying = false

    deinit {
        teardown()
    }

    /// 播放一首音频
    func play(urlString: String) {
        teardown()

        guard let url = URL(string: urlString), !urlString.isEmpty else {
            onError?("音频地址无效")
            return
        }

        configureAudioSession()
        onLoadingChanged?(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        statusObservation = item.observe(\AVPlayerItem.status) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.onLoadingChanged?(false)
            case .failed:
                self.onLoadingChanged?(false)
                self.onError?(item.error?.localizedDescription ?? "音频加载失败")
            default:
                break
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isPlaying = false
            self.onFinish?()
        }

        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.play()
        isPlaying = true
    }

    func stop() {
        teardown()
    }

    /// 播放进度（0...1），未知时返回 nil
    var progress: Double? {
        guard let player,
              let item = player.currentItem,
              item.duration.seconds.isFinite,
              item.duration.seconds > 0 else { return nil }
        return min(1.0, max(0, player.currentTime().seconds / item.duration.seconds))
    }

    // MARK: 内部

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        statusObservation?.invalidate()
        statusObservation = nil

        player?.pause()
        player = nil
        isPlaying = false
        onLoadingChanged?(false)
    }
}
