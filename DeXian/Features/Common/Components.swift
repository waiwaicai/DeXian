import SwiftUI

/// 通用 UI 组件：统一间距、圆角与层级。

// MARK: 远程封面（带缓存与占位）

struct CoverImage: View {
    let url: String?
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.sm

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
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let data = try await HTTPClient.shared.data(urlString: url, headers: ["Referer": url])
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            ImageCache.shared.store(decoded, for: url)
            image = decoded
        } catch {
            failed = true
        }
    }
}

/// 内存图片缓存
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
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
