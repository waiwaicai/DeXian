import SwiftUI

/// 设计系统：颜色 / 字体 / 间距 / 圆角 / 阴影。
///
/// 全部语义化，支持浅色与深色自动切换，保证各页面视觉统一。
enum Theme {

    // MARK: 颜色

    enum Palette {
        /// 品牌主色：青绿（取自 App 图标）
        static let brand = Color.dynamic(light: 0x0FA98A, dark: 0x45D9AE)
        /// 品牌深色：用于标题与图标
        static let brandDeep = Color.dynamic(light: 0x0A7D66, dark: 0x77E7C4)
        /// 点缀色：暖金，用于强调与进度
        static let accent = Color.dynamic(light: 0xC08A3E, dark: 0xE0B36A)
        /// 成功
        static let success = Color.dynamic(light: 0x2E9E5B, dark: 0x5FD98A)
        /// 警告
        static let warning = Color.dynamic(light: 0xC9722F, dark: 0xE09A5E)
        /// 危险
        static let danger = Color.dynamic(light: 0xC0453F, dark: 0xE5766F)
    }

    enum ColorToken {
        /// 页面背景
        static let background = Color.dynamic(light: 0xF6F7F9, dark: 0x111318)
        /// 卡片背景
        static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1B1E25)
        /// 次级面（输入框 / 分组背景）
        static let surfaceSecondary = Color.dynamic(light: 0xEFF1F5, dark: 0x23272F)
        /// 更高层级（弹层）
        static let surfaceElevated = Color.dynamic(light: 0xFFFFFF, dark: 0x272B34)
        /// 主文本
        static let textPrimary = Color.dynamic(light: 0x1C1F24, dark: 0xF2F4F7)
        /// 次级文本
        static let textSecondary = Color.dynamic(light: 0x5C6470, dark: 0xA9B1BD)
        /// 三级文本
        static let textTertiary = Color.dynamic(light: 0x8B939F, dark: 0x767E8A)
        /// 分割线
        static let separator = Color.dynamic(light: 0xE2E5EB, dark: 0x30353E)
        /// 主色文字
        static let brandText = Palette.brand
    }

    // MARK: 间距

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        /// 页面左右安全边距
        static let page: CGFloat = 16
        /// 卡片内边距
        static let card: CGFloat = 14
    }

    // MARK: 圆角

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
        static let pill: CGFloat = 999
    }

    // MARK: 阴影

    enum Shadow {
        /// 卡片投影：轻且柔和
        static let card = ShadowStyle(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
        static let raised = ShadowStyle(color: .black.opacity(0.10), radius: 18, x: 0, y: 8)
    }

    struct ShadowStyle {
        var color: Color
        var radius: CGFloat
        var x: CGFloat
        var y: CGFloat
    }
}

extension View {
    func themeShadow(_ style: Theme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    /// 统一卡片外观
    func cardStyle(padding: CGFloat = Theme.Spacing.card, radius: CGFloat = Theme.Radius.md) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.ColorToken.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.ColorToken.separator, lineWidth: 0.8)
            )
            .themeShadow(Theme.Shadow.card)
    }
}

// MARK: - 字体

extension Font {
    static let themeLargeTitle = Font.system(size: 30, weight: .bold, design: .rounded)
    static let themeTitle = Font.system(size: 22, weight: .bold)
    static let themeTitle2 = Font.system(size: 19, weight: .semibold)
    static let themeHeadline = Font.system(size: 16, weight: .semibold)
    static let themeBody = Font.system(size: 15, weight: .regular)
    static let themeCallout = Font.system(size: 14, weight: .regular)
    static let themeCaption = Font.system(size: 12.5, weight: .regular)
    static let themeCaptionBold = Font.system(size: 12.5, weight: .semibold)
    static let themeTiny = Font.system(size: 11, weight: .medium)
}

// MARK: - 颜色工具

extension Color {
    /// 根据浅色 / 深色模式生成自适应颜色。
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }

    init(hex: UInt32) {
        self.init(UIColor(rgb: hex))
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Bundle

extension Bundle {
    /// 当前版本号（如 1.0.2）
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    /// 构建号
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    /// 版本 + 构建号，用于「关于」页展示
    var fullVersion: String { shortVersion + " (" + buildNumber + ")" }
}
