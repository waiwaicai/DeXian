import SwiftUI
import Combine

/// 全局状态聚合
@MainActor
final class AppState: ObservableObject {
    let sources = SourceStore()
    let rss = RssStore()
    let shelf = ShelfStore()
    let settings = SettingsStore()

    /// 标签页选择
    @Published var selectedTab: RootView.Tab = .shelf
    /// 阅读页跳转目标
    @Published var readingBook: ShelfBook?
    @Published var toast: ToastMessage?

    struct ToastMessage: Identifiable, Equatable {
        var id = UUID()
        var text: String
        var style: ToastStyle = .info
    }

    enum ToastStyle {
        case info, success, failure
    }

    func show(_ text: String, style: ToastStyle = .info) {
        toast = ToastMessage(text: text, style: style)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast?.text == text { toast = nil }
        }
    }

    /// 打开阅读
    func openReader(_ book: ShelfBook) {
        readingBook = book
    }

    /// 把所有待写数据刷到磁盘（进入后台 / 退出时调用）
    func flushPendingWrites() {
        sources.flushPendingWrites()
        rss.flushPendingWrites()
        shelf.flushPendingWrites()
    }
}

/// 阅读与界面设置
@MainActor
final class SettingsStore: ObservableObject {

    enum Appearance: String, CaseIterable, Codable {
        case system, light, dark

        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// 阅读界面配色方案：黑底绿字等护眼组合
    enum ReaderTheme: String, CaseIterable, Codable {
        case paper          // 米白纸张
        case night          // 深灰夜间
        case blackGreen     // 纯黑底 + 绿字（护眼）
        case blackAmber     // 纯黑底 + 琥珀字
        case grayWhite      // 灰底白字

        var displayName: String {
            switch self {
            case .paper: return "纸白"
            case .night: return "夜间"
            case .blackGreen: return "黑底绿字"
            case .blackAmber: return "黑底琥珀"
            case .grayWhite: return "灰底白字"
            }
        }

        /// 页面背景色（0xRRGGBB）
        var backgroundColor: UInt32 {
            switch self {
            case .paper: return 0xFAF8F4
            case .night: return 0x101215
            case .blackGreen: return 0x000000
            case .blackAmber: return 0x000000
            case .grayWhite: return 0x2A2E33
            }
        }

        /// 正文文字色
        var textColor: UInt32 {
            switch self {
            case .paper: return 0x2A2D33
            case .night: return 0xC9CDD4
            case .blackGreen: return 0x39D353
            case .blackAmber: return 0xE0B36A
            case .grayWhite: return 0xF2F4F7
            }
        }

        /// 章节标题等次级文字的透明度
        var isDark: Bool { self != .paper }
    }

    enum PageTurn: String, CaseIterable, Codable {
        case scroll, cover, slide, none

        var displayName: String {
            switch self {
            case .scroll: return "滚动"
            case .cover: return "覆盖"
            case .slide: return "平移"
            case .none: return "无动画"
            }
        }
    }

    struct Snapshot: Codable {
        var appearance: Appearance
        var fontSize: Double
        var lineSpacing: Double
        var paragraphSpacing: Double
        var fontFamily: String
        var pageTurn: PageTurn
        var keepScreenOn: Bool
        var showProgress: Bool
        var comicFitWidth: Bool
        var fullScreen: Bool
        var textIndent: Bool
        var autoReadEnabled: Bool?
        var autoReadSpeed: Double?
        var autoReadContinuous: Bool?
        var readerTheme: ReaderTheme?
        var useSystemAppearanceForReader: Bool?
    }

    @Published var appearance: Appearance = .system { didSet { persist() } }
    @Published var fontSize: Double = 19 { didSet { persist() } }
    @Published var lineSpacing: Double = 8 { didSet { persist() } }
    @Published var paragraphSpacing: Double = 10 { didSet { persist() } }
    @Published var fontFamily: String = "系统" { didSet { persist() } }
    @Published var pageTurn: PageTurn = .scroll { didSet { persist() } }
    @Published var keepScreenOn: Bool = true { didSet { persist() } }
    @Published var showProgress: Bool = true { didSet { persist() } }
    @Published var comicFitWidth: Bool = true { didSet { persist() } }
    @Published var fullScreen: Bool = false { didSet { persist() } }
    @Published var textIndent: Bool = true { didSet { persist() } }
    @Published var autoReadEnabled: Bool = false { didSet { persist() } }
    /// 自动阅读速度（字 / 分钟）
    @Published var autoReadSpeed: Double = 420 { didSet { persist() } }
    /// 听书：读完一章自动进入下一章
    @Published var autoReadContinuous: Bool = true { didSet { persist() } }
    /// 阅读界面配色
    @Published var readerTheme: ReaderTheme = .paper { didSet { persist() } }
    /// 阅读界面是否跟随系统深色（关闭后强制使用所选配色）
    @Published var readerFollowsSystem: Bool = true { didSet { persist() } }

    init() {
        if let snapshot = FileStorage.load(Snapshot.self, from: "settings.json") {
            appearance = snapshot.appearance
            fontSize = snapshot.fontSize
            lineSpacing = snapshot.lineSpacing
            paragraphSpacing = snapshot.paragraphSpacing
            fontFamily = snapshot.fontFamily
            pageTurn = snapshot.pageTurn
            keepScreenOn = snapshot.keepScreenOn
            showProgress = snapshot.showProgress
            comicFitWidth = snapshot.comicFitWidth
            fullScreen = snapshot.fullScreen
            textIndent = snapshot.textIndent
            autoReadEnabled = snapshot.autoReadEnabled ?? false
            autoReadSpeed = snapshot.autoReadSpeed ?? 420
            autoReadContinuous = snapshot.autoReadContinuous ?? true
            readerTheme = snapshot.readerTheme ?? .paper
            readerFollowsSystem = snapshot.useSystemAppearanceForReader ?? true
        }
    }

    private func persist() {
        let snapshot = Snapshot(
            appearance: appearance,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            fontFamily: fontFamily,
            pageTurn: pageTurn,
            keepScreenOn: keepScreenOn,
            showProgress: showProgress,
            comicFitWidth: comicFitWidth,
            fullScreen: fullScreen,
            textIndent: textIndent,
            autoReadEnabled: autoReadEnabled,
            autoReadSpeed: autoReadSpeed,
            autoReadContinuous: autoReadContinuous,
            readerTheme: readerTheme,
            useSystemAppearanceForReader: readerFollowsSystem
        )
        FileStorage.save(snapshot, to: "settings.json")
    }

    /// 可选字体族。全部使用 iOS 自带字体，无需内置字体文件，
    /// 因此安装包依然很小，但选到的都是真正的宋体 / 楷体 / 圆体。
    static let fontFamilies = ["系统", "宋体", "楷体", "圆体", "等宽"]

    var readingFont: Font {
        switch fontFamily {
        //「Songti SC」是 iOS 自带的中文宋体
        case "宋体": return .custom("Songti SC", size: fontSize)
        //「Kaiti SC」是 iOS 自带的楷体
        case "楷体": return .custom("Kaiti SC", size: fontSize)
        case "圆体": return .system(size: fontSize, design: .rounded)
        case "等宽": return .system(size: fontSize, design: .monospaced)
        default: return .system(size: fontSize)
        }
    }
}
