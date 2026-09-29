import SwiftUI
import AVKit
import MediaPlayer

/// 视频播放内核：AVPlayer 封装 + 亮度 / 音量 / 进度。
///
/// 单独抽出来，是为了让 `VideoPlayerView` 专注布局与手势，
/// 也让「系统音量」这类需要 `MPVolumeView` 的操作集中在一处。
///
/// 刻意**不**标 `@MainActor`：拆解观察者必须在 `deinit` 里做，
/// 而 nonisolated 的 deinit 访问 actor 隔离的存储属性在 Swift 5.9 下
/// 属于并发错误。所有回调都走主队列，状态写入本来就落在主线程上。
final class VideoPlaybackController: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var duration: Double = 0
    /// 屏幕亮度（0...1），与系统亮度同步
    @Published private(set) var brightness: Double = Double(UIScreen.main.brightness)
    /// 媒体音量（0...1）
    @Published private(set) var volume: Double = 0

    let player = AVPlayer()

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    /// 用 MPVolumeView 里的 UISlider 写系统音量。
    ///
    /// AVAudioSession 没有「设置音量」的公开 API（只有读），
    /// 唯一稳妥做法就是驱动系统音量条本身的滑块。
    /// 该视图必须**加入视图层级**才生效，因此由播放器界面挂一个隐形的上去。
    static let volumeView = MPVolumeView(frame: .zero)

    private static var systemVolumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    init() {
        configureAudioSession()
        volume = Double(Self.systemVolumeSlider?.value ?? 1)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // 回调已经在主队列上，直接写即可
            guard let self else { return }
            self.currentSeconds = time.seconds.isFinite ? time.seconds : 0
            if let itemDuration = self.player.currentItem?.duration.seconds,
               itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
        }

        rateObservation = player.observe(\AVPlayer.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            self.isPlaying = player.rate > 0
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        rateObservation?.invalidate()
    }

    var hasItem: Bool { player.currentItem != nil }

    var currentTimeText: String { Self.format(currentSeconds) }
    var durationText: String { Self.format(duration) }

    // MARK: 加载与播放

    func load(url urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()

        let item = AVPlayerItem(url: url)
        // HLS 分片本来就边下边播，关掉可以少等一两秒才起播
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)
        currentSeconds = 0
        duration = 0
        isBuffering = true

        statusObservation = item.observe(\AVPlayerItem.status, options: [.new]) { [weak self] item, _ in
            // KVO 回调不保证在主线程，且这里要改 @Published，
            // 统一跳回主队列再写，避免多线程写同一个属性。
            let ready = item.status == .readyToPlay
            let failed = item.status == .failed
            guard ready || failed else { return }
            let seconds = item.duration.seconds
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBuffering = false
                if ready {
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    self.play()
                }
            }
        }

        // 播完自动下一集
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.isPlaying = false }
        }
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentSeconds = 0
        duration = 0
    }

    /// 跳转到指定秒数。拖动进度条与横滑快进都走这里。
    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        currentSeconds = target
        // tolerance 给一点余量：HLS 的关键帧不一定落在精确位置上，
        // 要求零误差会卡住不跳。
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.3, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.3, preferredTimescale: 600)
        )
    }

    // MARK: 亮度与音量

    func setBrightness(_ value: Double) {
        let clamped = min(1, max(0, value))
        brightness = clamped
        UIScreen.main.brightness = CGFloat(clamped)
    }

    func setVolume(_ value: Double) {
        let clamped = min(1, max(0, value))
        volume = clamped
        // 写滑块后需要手动发一次 valueChanged，系统音量 HUD 才会刷新
        if let slider = Self.systemVolumeSlider {
            slider.value = Float(clamped)
            slider.sendActions(for: .valueChanged)
        } else {
            player.volume = Float(clamped)
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback：视频要出声；不设 .moviePlayback 是因为短剧里也有纯音频
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// MPVolumeView 的宿主：给系统音量滑块一个「在场」的位置。
///
/// 音量写入依赖 `MediaPlayer` 里那个私有滑块，
/// 而该滑块只有在 MPVolumeView 被加入视图层级后才会创建。
struct SystemVolumeView: UIViewRepresentable {
    typealias UIViewType = MPVolumeView

    func makeUIView(context: Context) -> MPVolumeView {
        // 复用同一个实例：controller 里也是靠它写音量，
        // 各建一份会拿到不同的滑块，写值就落不到真正生效的那个上。
        VideoPlaybackController.volumeView
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// AVPlayerLayer 的 SwiftUI 包装。
///
/// 不用 `AVKit.VideoPlayer`：它自带一层系统控件，
/// 会和我们的自绘控制层叠在一起（两个暂停键）。
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    /// 用 layerClass 让整层直接就是 AVPlayerLayer，
    /// 省掉手动维护 frame 的布局代码（旋转时尤其容易错位）。
    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
