import SwiftUI
import UniformTypeIdentifiers

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
        } header: {
            Text("书源")
        } footer: {
            Text("支持导入阅读（Legado）格式书源，包括 yckceo 书源仓库的分享链接。")
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

/// 调试日志
struct LogViewerView: View {
    @State private var entries: [Log.Entry] = []
    @State private var crash: String?

    var body: some View {
        List {
            crashSection

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
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("刷新") { reload() }
                Button("清空", role: .destructive) {
                    Log.clear()
                    reload()
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
}
