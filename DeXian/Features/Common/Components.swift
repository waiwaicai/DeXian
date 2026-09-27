import SwiftUI

/// 通用 UI 组件：统一间距、圆角与层级。

// MARK: 远程封面（带缓存与占位）

struct CoverImage: View {
    let url: String?
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.sm
    /// 所属书源 id：用于带上该源的 Cookie，很多图床要登录态才给图
    var sourceKey: String?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.ColorToken.surfaceSecondary)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: failed ? "photo" : "book.closed")
                        .font(.system(size: min(width, height) * 0.28, weight: .light))
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Theme.ColorToken.separator.opacity(0.7), lineWidth: 0.5)
        )
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url, !url.isEmpty, image == nil else { return }
        // 封面只需按显示尺寸解码：原图动辄 2000x3000，全尺寸解码一张就是几十 MB，
        // 列表里滚几十张必然被系统以内存超限杀掉。
        let pixel = max(width, height)
        let loaded = await ImageLoader.shared.image(
            url: url,
            maxPixel: pixel,
            referer: url,
            sourceKey: sourceKey
        )
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }
}

/// 图片解码：统一走 ImageIO 下采样。
///
/// `UIImage(data:)` 会把原图按原始分辨率完整解码到内存，
/// 遇到超大图或畸形 PNG 会瞬间申请上百 MB 内存直接 OOM。
/// 先按目标像素尺寸生成缩略图，内存占用与显示尺寸挂钩。
enum ImageDecoder {
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 2
        let limit = max(1, maxPixel * scale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// 内存图片缓存。
///
/// 关键点：写入时必须带 cost。NSCache 只有在对象带 cost 时才按字节数计数，
/// 否则 totalCostLimit 形同虚设，只靠 countLimit 兜底，
/// 200 张原图足以把内存顶到 1GB 以上被系统强杀。
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    /// 失败记录：避免列表来回滚动时反复重试同一张坏图
    private var failedAt: [String: Date] = [:]
    private let lock = NSLock()
    private let failedTTL: TimeInterval = 90

    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 48 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
        lock.lock()
        failedAt[key] = nil
        lock.unlock()
    }

    func markFailed(_ key: String) {
        lock.lock()
        failedAt[key] = Date()
        lock.unlock()
    }

    func isFailed(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let date = failedAt[key] else { return false }
        if Date().timeIntervalSince(date) > failedTTL {
            failedAt[key] = nil
            return false
        }
        return true
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        failedAt.removeAll()
        lock.unlock()
    }
}

/// 图片加载器：同一地址的并发请求合并成一次网络请求，
/// 并负责 Referer 兜底与失败负缓存。
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private var running: [String: Task<UIImage?, Never>] = [:]

    func image(
        url: String,
        maxPixel: CGFloat,
        referer: String,
        sourceKey: String? = nil
    ) async -> UIImage? {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let key = value + "|" + String(Int(maxPixel))
        if let cached = ImageCache.shared.image(for: key) { return cached }
        if ImageCache.shared.isFailed(key) { return nil }
        if let task = running[key] { return await task.value }

        let task = Task<UIImage?, Never> {
            let result = await ImageLoader.fetch(
                url: value, maxPixel: maxPixel, referer: referer, sourceKey: sourceKey
            )
            return result
        }
        running[key] = task
        let loaded = await task.value
        running[key] = nil

        if let loaded {
            ImageCache.shared.store(loaded, for: key)
        } else {
            ImageCache.shared.markFailed(key)
        }
        return loaded
    }

    /// 依次尝试「章节页 Referer → 站点根 Referer」，
    /// 很多图床只认自己站点，Referer 给图片自身地址会直接 403。
    private static func fetch(
        url: String,
        maxPixel: CGFloat,
        referer: String,
        sourceKey: String?
    ) async -> UIImage? {
        for candidate in candidateReferers(referer: referer, imageURL: url) {
            var headers: [String: String] = [:]
            if !candidate.isEmpty { headers["Referer"] = candidate }
            if let data = try? await HTTPClient.shared.data(
                urlString: url,
                headers: headers,
                sourceKey: sourceKey,
                kind: .image
            ), let image = ImageDecoder.downsample(data, maxPixel: maxPixel) {
                return image
            }
        }
        return nil
    }

    private static func candidateReferers(referer: String, imageURL: String) -> [String] {
        var results: [String] = []
        let trimmed = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != imageURL { results.append(trimmed) }
        if let root = siteRoot(of: imageURL), !results.contains(root) { results.append(root) }
        if results.isEmpty { results.append("") }
        return results
    }

    private static func siteRoot(of value: String) -> String? {
        guard let url = URL(string: value), let scheme = url.scheme, let host = url.host else { return nil }
        return scheme + "://" + host + "/"
    }
}


// MARK: 标签

struct TagLabel: View {
    let text: String
    var color: Color = Theme.Palette.brand

    var body: some View {
        Text(text)
            .font(.themeTiny)
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.13))
            )
    }
}

// MARK: 分组标题

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(title)
                .font(.themeHeadline)
                .foregroundStyle(Theme.ColorToken.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 空状态

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Theme.ColorToken.surfaceSecondary)
                    .frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
            VStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.themeTitle2)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                Text(message)
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xxl)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.themeHeadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(Capsule().fill(Theme.Palette.brand))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }
}

// MARK: 加载态

struct LoadingView: View {
    var text: String = "加载中"

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Theme.Palette.brand)
            Text(text)
                .font(.themeCallout)
                .foregroundStyle(Theme.ColorToken.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.ColorToken.surface)
        )
        .themeShadow(Theme.Shadow.raised)
    }
}

// MARK: 主按钮

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.themeHeadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md + 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(enabled ? Theme.Palette.brand : Theme.ColorToken.textTertiary)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Toast

struct ToastView: View {
    let message: AppState.ToastMessage

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
            Text(message.text)
                .font(.themeCallout)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                .fill(color.opacity(0.95))
        )
        .themeShadow(Theme.Shadow.raised)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private var iconName: String {
        switch message.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch message.style {
        case .info: return Theme.Palette.brand
        case .success: return Theme.Palette.success
        case .failure: return Theme.Palette.danger
        }
    }
}

// MARK: 书籍列表行

struct SearchBookRow: View {
    let book: SearchBook
    var showSource: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            CoverImage(url: book.coverUrl, width: 62, height: 84)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(book.name)
                    .font(.themeHeadline)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(2)

                Text(book.displayAuthor)
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                    .lineLimit(1)

                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.themeCaption)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                        .lineLimit(2)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    if showSource {
                        TagLabel(text: book.originName, color: Theme.Palette.brand)
                    }
                    if let kind = book.kind, !kind.isEmpty {
                        TagLabel(text: kind, color: Theme.Palette.accent)
                    }
                    if let last = book.lastChapter, !last.isEmpty {
                        Text(last)
                            .font(.themeTiny)
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}
