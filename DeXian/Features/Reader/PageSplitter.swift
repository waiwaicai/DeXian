import Foundation
import UIKit

/// 按屏幕尺寸把一章正文切成「页」。
///
/// 阅读器要支持覆盖 / 平移 / 无动画三种翻页模式，就必须先知道
/// 一页能放下多少字。这里用 TextKit 的排版结果做二分：
///
/// - 二分本身是 O(log n)，单章（几千字）几十次测量即可完成；
/// - 优先在换行处断开，避免把一句话从中间截断；
/// - 完全离屏计算，不阻塞主线程。
enum PageSplitter {

    /// 排版参数（与正文渲染保持一致，否则会出现「算一页、显示半页」）
    struct Layout {
        var font: UIFont
        var lineSpacing: CGFloat
        /// 段落间距。
        ///
        /// 正文与测量现在都走 TextKit（见 `ReaderTextView`），
        /// `paragraphSpacing` 在两侧都会真实生效，因此这里直接采用设置值。
        ///
        /// 旧实现把测量固定成 0：那时正文是 SwiftUI 的 `Text`，
        /// 它不对 `\n` 应用段间距，于是翻页模式下「段落间距」这个设置
        /// 调了完全没有效果。改用 TextKit 后两侧一致，设置才真正生效。
        var paragraphSpacing: CGFloat
        /// 段首是否缩进两格
        var indent: Bool
        /// 一页可用高度
        var height: CGFloat
        /// 一页可用宽度
        var width: CGFloat
        /// 是否两端对齐。
        ///
        /// 必须参与测量：两端对齐会把行内字距拉开，断行位置与左对齐
        /// 并不完全相同。测量与渲染用了不同的对齐方式，
        /// 就会出现「算得下、画出来被裁」。
        var justified: Bool = true

        var isValid: Bool { height > 40 && width > 40 }
    }

    /// 单章超过这个长度直接当一页处理，避免极端正文把二分算到超时
    private static let maxCharacters = 200_000

    static func paginate(text: String, layout: Layout) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        guard layout.isValid, normalized.count <= maxCharacters else { return [normalized] }

        let ns = normalized as NSString
        let attributes = attributes(for: layout)
        var pages: [String] = []
        var start = 0

        while start < ns.length {
            let fitting = longestFittingLength(
                in: ns, from: start, attributes: attributes, layout: layout
            )
            // 至少要吃掉一个字符，否则会被空行之类的情况卡住
            let length = max(1, fitting)
            let end = min(start + length, ns.length)

            // 优先在换行处断开，让段落尽量完整。
            //
            // 但回退窗口必须收紧：页面要「填满」，而不是「尽量断在段落处」。
            // 旧实现允许回退到本页的 65% 处，等于最多丢掉 35% 的容量；
            // 而每行容纳的字符数随字号增大而减少，同样的比例在放大字号后
            // 丢掉的行数更多 —— 用户看到的「有些书字体放大以后没有铺满全屏、
            // 下方留一大片空」就是这个回退造成的。
            // 现在最多回退 1.5 行（并额外限制在 12% 容量以内），
            // 段落断点只在「相邻不远处」才作为优化生效。
            var cut = end
            let charactersPerLine = max(1, Int(layout.width / max(8, layout.font.pointSize)))
            let backtrack = min(Int(Double(length) * 0.12), charactersPerLine + charactersPerLine / 2)
            let lowerBound = max(start, end - backtrack)
            if end < ns.length, lowerBound < end {
                let searchRange = NSRange(location: lowerBound, length: end - lowerBound)
                let newline = ns.range(of: "\n", options: .backwards, range: searchRange)
                if newline.location != NSNotFound, newline.location > start {
                    cut = newline.location + newline.length
                }
            }

            let piece = ns.substring(with: NSRange(location: start, length: cut - start))
                .trimmingCharacters(in: .newlines)
            if !piece.isEmpty { pages.append(piece) }
            start = cut
        }

        return pages.isEmpty ? [normalized] : pages
    }

    /// 查找「从 start 开始、不超过一页高度」的最大字符数。
    ///
    /// 先用字体度量估一个「每页大概多少字」，再从这个估计值做倍增 + 二分。
    ///
    /// 不能直接在 [1, 剩余全文] 上二分：那会让每次试探都去排版半个章节，
    /// 一章一测就是几十毫秒，几十页叠加起来要好几秒。
    /// 估计值把搜索窗口压到一个页面的量级，整体复杂度回到线性。
    private static func longestFittingLength(
        in ns: NSString,
        from start: Int,
        attributes: [NSAttributedString.Key: Any],
        layout: Layout
    ) -> Int {
        let remaining = ns.length - start
        guard remaining > 1 else { return max(1, remaining) }

        let hint = estimatedCharactersPerPage(layout: layout)
        var high = min(remaining, max(1, hint))

        // 倍增：估计值装得下就继续往上翻倍，直到装不下或到顶
        while high < remaining {
            let candidate = ns.substring(with: NSRange(location: start, length: high))
            if height(of: candidate, attributes: attributes, layout: layout) <= layout.height {
                high = min(remaining, high * 2)
            } else {
                break
            }
        }

        // 二分收窄到精确值
        var best = 1
        var lb = 1
        var hb = high
        while lb <= hb {
            let mid = (lb + hb) / 2
            let candidate = ns.substring(with: NSRange(location: start, length: mid))
            if height(of: candidate, attributes: attributes, layout: layout) <= layout.height {
                best = mid
                lb = mid + 1
            } else {
                hb = mid - 1
            }
        }
        return max(1, best)
    }

    /// 按字体度量估算一页能放多少字符（中文按一个字宽 ≈ 字号，英文更窄）
    private static func estimatedCharactersPerPage(layout: Layout) -> Int {
        let fontSize = max(8, layout.font.pointSize)
        let effectiveLineHeight = max(fontSize, layout.font.lineHeight) + layout.lineSpacing
        let lines = max(1, Int(layout.height / effectiveLineHeight))
        // 中文一个字宽约等于字号，按字号估算行内字数即可
        let perLine = max(1, Int(layout.width / fontSize))
        // 留 20% 余量，避免估计值偏小导致倍增轮数过多
        return Int(Double(lines * perLine) * 1.2)
    }

    private static func height(
        of text: String,
        attributes: [NSAttributedString.Key: Any],
        layout: Layout
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        // attributes 由 `attributes(for:)` 产出，其中的段落样式来自
        // `ReaderTextStyle.paragraphStyle`，与正文渲染（`ReaderTextView`）
        // 用的是同一份定义。量法与画法一致，才不会出现
        // 「算得下、画出来被裁掉末行」。
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let box = attributed.boundingRect(
            with: CGSize(width: layout.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(box.height)
    }

    /// 与正文渲染一致的排版属性。
    ///
    /// 直接复用 `ReaderTextStyle`，保证「量高度」和「画文字」
    /// 用的是同一份段落样式 —— 这是分页准确性的前提。
    private static func attributes(for layout: Layout) -> [NSAttributedString.Key: Any] {
        let paragraph = ReaderTextStyle.paragraphStyle(
            lineSpacing: layout.lineSpacing,
            paragraphSpacing: layout.paragraphSpacing,
            justified: layout.justified
        )
        // 首行缩进与正文里的「　　」保持一致
        if layout.indent {
            paragraph.firstLineHeadIndent = layout.font.pointSize * 2
            paragraph.headIndent = layout.font.pointSize * 2
        }
        return [
            .font: layout.font,
            .paragraphStyle: paragraph
        ]
    }

    /// 把设置里的字体族名转成 UIFont。
    ///
    /// 分页测量与实际渲染必须用同一个字体对象，
    /// 否则「一页能放多少字」算出来和画出来不一致，
    /// 就会出现末行被裁掉或每页留白一大截。
    static func uiFont(family: String, size: CGFloat) -> UIFont {
        switch family {
        case "宋体":
            return UIFont(name: "Songti SC", size: size) ?? .systemFont(ofSize: size)
        case "楷体":
            return UIFont(name: "Kaiti SC", size: size) ?? .systemFont(ofSize: size)
        case "圆体":
            // SwiftUI 的 .rounded 设计在 UIKit 里要走 font descriptor
            let base = UIFont.systemFont(ofSize: size)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        case "等宽":
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return UIFont.systemFont(ofSize: size)
        }
    }
}
