import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 我的：书源管理入口 + 阅读设置 + 关于
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var rss: RssStore
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            List {
                sourceSection
                rssSection
                readingSection
                appearanceSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: 书源

    private var sourceSection: some View {
        Section {
            NavigationLink {
                SourceListView()
            } label: {
                settingsRow(
                    icon: "server.rack",
                    color: Theme.Palette.brand,
                    title: "书源管理",
                    detail: String(sources.sources.count) + " 个 · 已启用 " + String(sources.enabledSources.count)
                )
            }

            NavigationLink {
                ImportSourceView()
            } label: {
                settingsRow(
                    icon: "square.and.arrow.down",
                    color: Theme.Palette.accent,
                    title: "导入书源",
                    detail: "支持 JSON / 链接 / 剪贴板"
                )
            }

            NavigationLink {
                SourceProbeView()
            } label: {
                settingsRow(
                    icon: "stethoscope",
                    color: Theme.Palette.warning,
                    title: "书源探测",
                    detail: "筛出失效源并一键清除"
                )
            }

            NavigationLink {
                PurifierEditorView()
            } label: {
                settingsRow(
                    icon: "wand.and.stars",
                    color: Theme.Palette.success,
                    title: "正文净化规则",
                    detail: settings.purifierRulesJSON.isEmpty ? "内置规则 + 书源规则" : "自定义 + 书源规则"
                )
            }
        } header: {
            Text("书源")
        } footer: {
            Text("支持 Legado 书源与 yckceo 分享链接。自动移除推广链接、更新提示和站内导航；"
                 + "失效源可探测清理，也可添加自定义净化正则。")
        }
    }

    // MARK: 订阅源

    private var rssSection: some View {
        Section {
            NavigationLink {
                RssSourceListView()
            } label: {
                settingsRow(
                    icon: "dot.radiowaves.left.and.right",
                    color: Theme.Palette.success,
                    title: "订阅源管理",
                    detail: String(rss.sources.count) + " 个 · 已启用 " + String(rss.enabledSources.count)
                )
            }

            NavigationLink {
                ImportRssSourceView()
            } label: {
                settingsRow(
                    icon: "square.and.arrow.down.on.square",
                    color: Theme.Palette.warning,
                    title: "导入订阅源",
                    detail: "支持 yckceo RSS JSON"
                )
            }
        } header: {
            Text("订阅源")
        } footer: {
            Text("订阅源用于订阅网站的文章与图片，支持 yckceo 的 RSS 订阅源仓库。")
        }
    }

    // MARK: 阅读

    private var readingSection: some View {
        Section("阅读") {
            Picker(selection: $settings.appearance) {
                ForEach(SettingsStore.Appearance.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            } label: {
                settingsRow(icon: "circle.lefthalf.filled", color: Theme.Palette.brand,
                            title: "外观", detail: nil)
            }

            Picker(selection: $settings.pageTurn) {
                ForEach(SettingsStore.PageTurn.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            } label: {
                settingsRow(icon: "arrow.left.arrow.right", color: Theme.Palette.success,
                            title: "翻页动画", detail: nil)
            }

            HStack {
                settingsRow(icon: "textformat.size", color: Theme.Palette.accent, title: "字号", detail: nil)
                Spacer()
                Stepper("", value: $settings.fontSize, in: 14...30, step: 1)
                    .labelsHidden()
                Text(String(Int(settings.fontSize)))
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                    .frame(width: 30, alignment: .trailing)
            }

            HStack {
                settingsRow(icon: "text.alignleft", color: Theme.Palette.success, title: "行距", detail: nil)
                Spacer()
                Slider(value: $settings.lineSpacing, in: 0...24, step: 1)
                    .frame(maxWidth: 160)
                Text(String(Int(settings.lineSpacing)))
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                    .frame(width: 30, alignment: .trailing)
            }

            Picker(selection: $settings.fontFamily) {
                ForEach(SettingsStore.fontFamilies, id: \.self) { name in
                    Text(name).tag(name)
                }
            } label: {
                settingsRow(icon: "character", color: Theme.Palette.brand, title: "字体", detail: nil)
            }

            Picker(selection: $settings.readerTheme) {
                ForEach(SettingsStore.ReaderTheme.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            } label: {
                settingsRow(icon: "circle.righthalf.filled", color: Theme.Palette.warning, title: "阅读配色", detail: nil)
            }

            Toggle(isOn: $settings.comicFitWidth) {
                settingsRow(icon: "photo", color: Theme.Palette.warning, title: "漫画适应宽度", detail: nil)
            }

            Toggle(isOn: $settings.showProgress) {
                settingsRow(icon: "chart.bar", color: Theme.Palette.brand, title: "显示阅读进度", detail: nil)
            }

            HStack {
                settingsRow(icon: "headphones", color: Theme.Palette.success, title: "朗读语速", detail: nil)
                Spacer()
                Stepper("", value: $settings.autoReadSpeed, in: 180...900, step: 20)
                    .labelsHidden()
                Text(String(Int(settings.autoReadSpeed)) + " 字/分")
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
            }
        }
    }

    private var appearanceSection: some View {
        Section("书架") {
            HStack {
                settingsRow(icon: "books.vertical", color: Theme.Palette.brand, title: "藏书", detail: nil)
                Spacer()
                Text(String(shelf.books.count) + " 本")
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
            }

            Button {
                let text = sources.exportJSON()
                UIPasteboard.general.string = text
                appState.show("已复制 " + String(sources.sources.count) + " 个书源到剪贴板", style: .success)
            } label: {
                settingsRow(icon: "doc.on.doc", color: Theme.Palette.accent,
                            title: "导出全部书源", detail: "复制 JSON 到剪贴板")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                settingsRow(icon: "info.circle", color: Theme.ColorToken.textTertiary, title: "版本", detail: nil)
                Spacer()
                Text(Bundle.main.fullVersion)
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
            }
            NavigationLink {
                LogViewerView()
            } label: {
                settingsRow(icon: "ladybug", color: Theme.ColorToken.textTertiary,
                            title: "调试日志", detail: "排查书源问题")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("得闲仅提供阅读工具，所有内容均来自第三方书源，请支持正版。")
        }
    }

    private func settingsRow(icon: String, color: Color, title: String, detail: String?) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(color)
                )

            Text(title)
                .font(.themeBody)

            Spacer(minLength: 0)

            if let detail {
                Text(detail)
                    .font(.themeCaption)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            }
        }
    }
}

/// 正文净化规则编辑器。
///
/// 使用 JSON 数组，兼容三种写法：
/// `{"name":"去推广","pattern":"正则","replacement":""}`、
/// `{"name":"替换","find":"原文","replace":"新文"}`、`"广告文案"`。
struct PurifierEditorView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var text: String = ""
    @State private var sample: String = "正文第一段。\n请收藏本站 www.example.com\n本章未完，请点击下一页继续阅读。"

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("规则 JSON")
            } footer: {
                Text("留空只使用内置净化。示例：\n[{\"name\":\"去推广\",\"pattern\":\"请收藏本站.*\",\"replacement\":\"\"}]")
            }

            Section {
                TextEditor(text: $sample)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 110)
                Button {
                    apply()
                } label: {
                    Label("测试并保存", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    settings.purifierRulesJSON = ""
                    text = ""
                    appState.show("已恢复内置净化", style: .success)
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("预览")
            }
        }
        .navigationTitle("正文净化规则")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = settings.purifierRulesJSON }
    }

    private func apply() {
        let purifier = ContentPurifier(sourceRule: nil, userRulesJSON: text)
        let output = purifier.purify(sample)
        settings.purifierRulesJSON = text.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.show("已保存；预览结果 \(output.count) 字", style: .success)
    }
}

/// 调试日志
struct LogViewerView: View {
    @State private var entries: [Log.Entry] = []
    @State private var crash: String?
    /// 复制 / 分享后的短暂提示：操作没有可见反馈时，
    /// 用户会以为按钮没生效而反复点。
    @State private var hint: String?
    @State private var showShare = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            crashSection

            // 日志文本可长按选中，也可以整份复制 / 分享。
            // 反馈问题时把日志贴出来，比截图强得多 ——
            // 截图里的报错信息没法搜索、也贴不进聊天工具。
            if !entries.isEmpty {
                Section {
                    Button {
                        copyAll()
                    } label: {
                        Label("复制全部日志", systemImage: "doc.on.doc")
                    }
                    Button {
                        showShare = true
                    } label: {
                        Label("分享日志文本", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        exportTXT()
                    } label: {
                        Label("导出 TXT 文件", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("长按任意一条日志可单独复制。")
                        .font(.themeTiny)
                }
            }

            if entries.isEmpty {
                Text("暂无日志")
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack {
                            Text(entry.category)
                                .font(.themeTiny)
                                .foregroundStyle(Theme.Palette.brand)
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.themeTiny)
                                .foregroundStyle(Theme.ColorToken.textTertiary)
                        }
                        Text(entry.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                            // 单条也能长按选中 / 拷贝
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let hint {
                Text(hint)
                    .font(.themeCaption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Capsule().fill(Theme.Palette.brand.opacity(0.95)))
                    .padding(.bottom, Theme.Spacing.xl)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: hint)
        .sheet(isPresented: $showShare) {
            ShareTextView(text: plainLogText)
        }
        .sheet(item: $exportURL) { url in
            ShareFileView(url: url)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("刷新") { reload() }
                    Button("复制全部", action: copyAll)
                    Button("分享", action: { showShare = true })
                    Button("清空", role: .destructive) {
                        Log.clear()
                        reload()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { reload() }
    }

    /// 上次闪退的现场。没有崩溃时整段不显示。
    @ViewBuilder
    private var crashSection: some View {
        if let crash {
            Section {
                ScrollView {
                    Text(crash)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)

                Button("清除崩溃记录", role: .destructive) {
                    CrashReporter.clear()
                    reload()
                }
            } header: {
                Text("上次闪退现场")
            }
        }
    }

    private func reload() {
        entries = Log.recent.reversed()
        crash = CrashReporter.lastReport
    }

    /// 日志的纯文本形态：时间 + 分类 + 正文，一行一条。
    ///
    /// 崩溃现场也带上 —— 排查闪退时它比日志本身更关键，
    /// 只复制日志会让用户再去截图一次。
    private var plainLogText: String {
        var lines: [String] = []
        lines.append("得闲 DeXian 调试日志")
        lines.append("版本 " + Bundle.main.shortVersion)
        lines.append("导出时间 " + Date().formatted(date: .numeric, time: .standard))
        lines.append("")
        for entry in entries.reversed() {
            let time = entry.date.formatted(date: .omitted, time: .standard)
            lines.append("[" + time + "] [" + entry.category + "] " + entry.message)
        }
        if let crash, !crash.isEmpty {
            lines.append("")
            lines.append("=== 上次闪退现场 ===")
            lines.append(crash)
        }
        return lines.joined(separator: "\n")
    }

    private func copyAll() {
        let text = plainLogText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        showHint(text.isEmpty ? "没有可复制的内容" : "已复制 " + String(text.count) + " 个字符")
    }

    private func exportTXT() {
        let text = plainLogText
        guard !text.isEmpty else {
            showHint("没有可导出的日志")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "DeXian-debug-" + formatter.string(from: Date()) + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            exportURL = url
            showHint("已生成 " + name)
        } catch {
            showHint("导出失败：" + error.localizedDescription)
        }
    }

    private func showHint(_ text: String) {
        hint = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if hint == text { hint = nil }
        }
    }
}

/// 系统分享面板：把日志文本发给微信 / 备忘录 / 邮件等。
///
/// 用 `UIActivityViewController` 而不是 SwiftUI 的 `ShareLink`：
/// `ShareLink` 在 iOS 16 上对「纯文本 + 大段内容」的分享项
/// 会走 `Transferable`，中文换行偶发被转义成可见的 `\n`。
/// 这里直接交 NSString，行为与复制完全一致。
struct ShareTextView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text as NSString], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 文件分享：导出 TXT 用真实文件，保存到“文件”或发送给微信 / 邮件。
struct ShareFileView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
