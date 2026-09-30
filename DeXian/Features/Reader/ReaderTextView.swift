import SwiftUI
import UIKit

/// 正文排版样式。**分页测量与正文渲染必须共用这一份**。
///
/// 旧实现是两套：`PageSplitter` 用 `NSAttributedString` 量高度，
/// 正文用 SwiftUI 的 `Text` 画。两套引擎对 `\n`、段间距、字距的处理
/// 并不相同，于是「算出来一页能放 20 行、实际只画出 17 行」，
/// 末行被裁掉或每页底部空一大截。
///
/// 现在测量与渲染都走 TextKit，并且共用下面的段落样式，
/// 这类问题从根上消失。
enum ReaderTextStyle {

    /// 段落样式。
    ///
    /// - Parameter justified: 两端对齐。SwiftUI 的 `Text` 没有这个选项，
    ///   中文正文右边界因此参差不齐（实测右余量在 28~38pt 之间抖动），
    ///   视觉上就像「没有铺满、整体偏左」——正是用户反复反馈的现象。
    ///   TextKit 的两端对齐会把行内字距拉开，让除段落末行外的每一行都顶到右边界。
    static func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        justified: Bool
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        style.alignment = justified ? .justified : .natural
        // 中文正文不做断词：开了之后 TextKit 会在行末插连字符，
        // 中文场景只会平白多出「-」。
        style.hyphenationFactor = 0
        return style
    }

    /// 组装正文的富文本属性。
    static func attributes(
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        justified: Bool
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                justified: justified
            )
        ]
    }

    /// 排版高度。
    ///
    /// **全应用只留这一份「量文字高度」的实现**：
    /// 滚动模式的自适应高度、`PageSplitter` 的分页测量都走它。
    /// 各写一份的话，两边参数一旦不同步，就会出现
    /// 「分页算得下、实际画出来被裁掉末行」。
    ///
    /// 用 `boundingRect` 而不是 `UITextView.sizeThatFits`：
    /// 后者依赖视图当前 bounds 的宽度，而测量发生时视图尺寸还没更新，
    /// 宽度变化（旋转、分屏、改字号）时会量出旧宽度的结果。
    static func height(
        of text: String,
        font: UIFont,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        justified: Bool,
        width: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let attributed = NSAttributedString(
            string: text,
            attributes: attributes(
                font: font,
                color: .label,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                justified: justified
            )
        )
        let box = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(box.height)
    }
}

/// 正文渲染视图。
///
/// 用 `UITextView`（TextKit）而不是 SwiftUI 的 `Text`，有两个原因：
///
/// 1. **两端对齐**：SwiftUI 的 `Text` 没有 `.justified`。
/// 2. **与分页测量同源**：`PageSplitter` 的度量就是
///    `NSAttributedString.boundingRect`，也是 TextKit。渲染改用 TextKit 后，
///    「量出来放得下、画出来被裁掉」这一类问题不再存在。
///
/// 视图本身**不滚动**（`isScrollEnabled = false`），高度按内容自适应：
/// 滚动模式由外层 `ScrollView` 负责滚动，翻页模式由外层固定一屏。
/// 这样这个视图在任何一处都是「有多大就报多大」，不会自己吃掉滚动手势
/// （之前透明层吃手势导致「页面滑不动」的问题也一并被规避）。
struct ReaderTextView: UIViewRepresentable {
    var text: String
    var font: UIFont
    var color: UIColor
    var lineSpacing: CGFloat
    /// 段间距。正文里的段落以 `\n` 分隔，由 TextKit 按这个值排版。
    var paragraphSpacing: CGFloat
    /// 是否允许选中复制（滚动模式开，翻页模式关：选中会干扰翻页手势）
    var selectable: Bool
    var justified: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        // 不滚动：高度完全由内容决定，滚动交给外层容器
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        // 去掉 TextKit 默认的内边距，让正文左边缘与容器左边缘严格对齐。
        // 少了这一步，UILabel/UILabel 风格会多出 5pt 的 lineFragmentPadding，
        // 左右就不对称了。
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        // 不要自动识别链接 / 电话：正文里出现网址时会被画成蓝色可点，
        // 既影响阅读也会吃掉点击手势。
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = false
        view.contentInsetAdjustmentBehavior = .never
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isSelectable = selectable
        // 选中高亮用主题色，深色背景下系统默认的蓝色很刺眼
        view.tintColor = color
        view.attributedText = NSAttributedString(
            string: text,
            attributes: ReaderTextStyle.attributes(
                font: font,
                color: color,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                justified: justified
            )
        )
    }

    /// 高度按实际的 TextKit 排版结果上报。
    ///
    /// 用与 `PageSplitter` 完全相同的度量函数，并向上多留 2pt：
    /// 测量只要比实际渲染略小一点，最后一行就会被 `UITextView` 裁掉；
    /// 略大则只是多出一行都不到的空隙，肉眼看不出来。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        // 宽度未知（第一次布局）时返回 nil，让 SwiftUI 用理想尺寸，
        // 等真实宽度回来再量 —— 用 0 宽度量出来的高度是错的。
        guard let width = proposal.width, width.isFinite, width > 1 else { return nil }
        let height = ReaderTextStyle.height(
            of: text,
            font: font,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            justified: justified,
            width: width
        )
        return CGSize(width: width, height: height + 2)
    }
}
