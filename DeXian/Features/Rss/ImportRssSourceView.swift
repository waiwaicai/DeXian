import SwiftUI
import UniformTypeIdentifiers

/// 订阅源导入：本地文件 / 剪贴板 / 网络链接 / 二维码。
/// 与书源导入共用 SourceImporter，只把结果落到 RssStore。
struct ImportRssSourceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var rss: RssStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isImporting = false
    @State private var showFilePicker = false
    @State private var lastResult: String?
    @State private var lastStyle: AppState.ToastStyle = .info
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    methodCards
                    urlCard
                    helpCard

                    if let lastResult {
                        resultCard(lastResult)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.lg)
            }

            if isImporting {
                LoadingView(text: "正在导入订阅源")
            }
        }
        .navigationTitle("导入订阅源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("关闭") { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFile(result)
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { value in
                showScanner = false
                urlText = value
                Task { await importFromURL() }
            }
        }
    }

    // MARK: 导入方式

    private var methodCards: some View {
        VStack(spacing: Theme.Spacing.md) {
            SectionHeader(title: "导入方式", systemImage: "square.and.arrow.down")

            HStack(spacing: Theme.Spacing.md) {
                methodCard(
                    title: "剪贴板",
                    subtitle: "已复制的 JSON / 链接",
                    systemImage: "doc.on.clipboard",
                    color: Theme.Palette.brand
                ) {
                    Task { await importFromClipboard() }
                }

                methodCard(
                    title: "本地文件",
                    subtitle: "选择 .json / .txt",
                    systemImage: "folder",
                    color: Theme.Palette.accent
                ) {
                    showFilePicker = true
                }
            }

            methodCard(
                title: "扫二维码",
                subtitle: "扫描订阅源分享二维码",
                systemImage: "qrcode.viewfinder",
                color: Theme.Palette.success
            ) {
                showScanner = true
            }
        }
    }

    private func methodCard(
        title: String,
        subtitle: String,
        systemImage: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(color)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.themeHeadline)
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                    Text(subtitle)
                        .font(.themeCaption)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
            .cardStyle(padding: Theme.Spacing.md)
        }
        .buttonStyle(.plain)
    }

    // MARK: 链接

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "从链接导入", systemImage: "link")

            VStack(spacing: Theme.Spacing.md) {
                TextField("https://... 或订阅源 JSON 文本", text: $urlText, axis: .vertical)
                    .font(.themeCallout)
                    .lineLimit(2...6)
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(Theme.ColorToken.surfaceSecondary)
                    )

                Button {
                    Task { await importFromURL() }
                } label: {
                    Text("导入")
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !urlText.trimmingCharacters(in: .whitespaces).isEmpty))
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .cardStyle(padding: Theme.Spacing.md)
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "yckceo 订阅源", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                bullet("订阅源地址格式：https://www.yckceo.com/yuedu/rss/json/id/898.json")
                bullet("支持带规则的源（ruleArticles / ruleTitle / ruleLink）")
                bullet("也支持无规则的纯链接源（直接罗列页面链接）")
                bullet("同一份 JSON 里混有书源时会自动只取订阅源")
            }
            .cardStyle(padding: Theme.Spacing.md)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.themeCaption)
                .foregroundStyle(Theme.ColorToken.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func resultCard(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: lastStyle == .failure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(lastStyle == .failure ? Theme.Palette.danger : Theme.Palette.success)
            Text(text)
                .font(.themeCallout)
                .foregroundStyle(Theme.ColorToken.textPrimary)
            Spacer(minLength: 0)
        }
        .cardStyle(padding: Theme.Spacing.md)
    }

    // MARK: 动作

    private func importFromClipboard() async {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            finish("剪贴板没有内容", style: .failure)
            return
        }
        await apply(text: text)
    }

    private func importFromURL() async {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        if value.hasPrefix("[") || value.hasPrefix("{") {
            let result = await SourceImporter.parseInBackground(text: value, preferRss: true)
            await handle(result: result)
            return
        }

        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            finish("链接格式不正确", style: .failure)
            return
        }

        do {
            let result = try await SourceImporter.importFromURL(value, preferRss: true)
            await handle(result: result)
        } catch {
            finish("下载失败：" + error.localizedDescription, style: .failure)
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            Task { @MainActor in
                let imported = await SourceImporter.importInBackground(fromFile: url, preferRss: true)
                isImporting = false
                await handle(result: imported)
            }
        case .failure(let error):
            finish("选择文件失败：" + error.localizedDescription, style: .failure)
        }
    }

    @MainActor
    private func apply(text: String) async {
        isImporting = true
        let result = await SourceImporter.parseInBackground(text: text, preferRss: true)
        isImporting = false
        await handle(result: result)
    }

    @MainActor
    private func handle(result: ImportResult) async {
        guard result.hasRssSources else {
            if result.hasBookSources {
                finish("这是书源，请到「书源管理 → 导入书源」导入", style: .failure)
            } else {
                finish(result.warnings.first ?? "未识别到有效订阅源", style: .failure)
            }
            return
        }
        let merged = rss.add(result.rssSources)
        var message = "已导入 " + String(merged.added) + " 个订阅源"
        if merged.updated > 0 { message += "，更新 " + String(merged.updated) + " 个" }
        if !result.sources.isEmpty {
            message += "；同时检测到 " + String(result.sources.count) + " 个书源，请到「书源管理 → 导入书源」导入"
        }
        finish(message, style: .success)
        appState.show(message, style: .success)
    }

    private func finish(_ message: String, style: AppState.ToastStyle) {
        lastResult = message
        lastStyle = style
    }
}
