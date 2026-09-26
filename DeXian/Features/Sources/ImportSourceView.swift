import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AudioToolbox

/// 书源导入：本地文件 / 剪贴板 / 网络链接 / 二维码
struct ImportSourceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var rss: RssStore

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
                LoadingView(text: "正在导入书源")
            }
        }
        .navigationTitle("导入书源")
        .navigationBarTitleDisplayMode(.inline)
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
                subtitle: "扫描书源分享二维码",
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
                TextField("https://... 或 bookSource JSON 文本", text: $urlText, axis: .vertical)
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
            SectionHeader(title: "支持格式", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                bullet("阅读（Legado）书源 JSON：数组或单个对象")
                bullet("网络链接：直接指向 JSON 文件")
                bullet("分享链接：内含 Base64 编码的书源")
                bullet("分享文本：粘贴后自动识别其中的 JSON")
                bullet("二维码：内容为上述任意形式")
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
        await apply(text: text, source: "剪贴板")
    }

    private func importFromURL() async {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        // 直接是 JSON 文本
        if value.hasPrefix("[") || value.hasPrefix("{") {
            await apply(text: value, source: "文本")
            return
        }

        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            finish("链接格式不正确", style: .failure)
            return
        }

        do {
        let result = try await SourceImporter.importFromURL(value)
            await handle(result: result, source: "链接")
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
                // 读取与解析都在后台，超大文件不会卡住界面
                let imported = await SourceImporter.importInBackground(fromFile: url)
                isImporting = false
                await handle(result: imported, source: url.lastPathComponent)
            }
        case .failure(let error):
            finish("选择文件失败：" + error.localizedDescription, style: .failure)
        }
    }

    @MainActor
    private func apply(text: String, source: String) async {
        isImporting = true
        let result = await SourceImporter.parseInBackground(text: text)
        isImporting = false
        await handle(result: result, source: source)
    }

    @MainActor
    private func handle(result: ImportResult, source: String) async {
        // 混有订阅源时一并入库，避免用户再导一次
        var rssMessage = ""
        if result.hasRssSources {
            let mergedRss = rss.add(result.rssSources)
            rssMessage = "订阅源 " + String(mergedRss.added) + " 个"
        }

        guard result.hasBookSources else {
            if result.hasRssSources {
                finish("已导入 " + rssMessage, style: .success)
                appState.show("已导入 " + rssMessage, style: .success)
            } else {
                finish(result.warnings.first ?? "未识别到有效书源", style: .failure)
            }
            return
        }
        // 合并去重也在后台完成
        let merged = await sources.addInBackground(result.sources)
        var message = "已导入 " + String(merged.added) + " 个"
        if merged.updated > 0 { message += "，更新 " + String(merged.updated) + " 个" }
        if result.skipped > 0 { message += "，跳过 " + String(result.skipped) + " 个无效条目" }
        if !rssMessage.isEmpty { message += "；" + rssMessage }
        finish(message + "（" + result.detectedFormat + "）", style: .success)
        appState.show(message, style: .success)
    }

    private func finish(_ message: String, style: AppState.ToastStyle) {
        lastResult = message
        lastStyle = style
    }
}

/// 二维码扫描（使用 AVFoundation）
struct QRScannerView: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                QRScannerRepresentable(onResult: onResult)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("将二维码放入取景框")
                        .font(.themeCallout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.bottom, Theme.Spacing.xxl)
                }
            }
            .navigationTitle("扫描二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// 二维码识别
struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onResult = onResult
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr, .ean13, .code128]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        Task.detached { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        hasReported = true
        AudioServicesPlaySystemSound(1057)
        onResult?(value)
    }
}
