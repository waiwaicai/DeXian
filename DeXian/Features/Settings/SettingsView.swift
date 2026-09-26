import SwiftUI
import UniformTypeIdentifiers

/// 我的：书源管理入口 + 阅读设置 + 关于
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            List {
                sourceSection
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
        } header: {
            Text("书源")
        } footer: {
            Text("支持导入阅读（Legado）格式书源，包括 yckceo 书源仓库的分享链接。")
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
                Text("1.0.0")
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

    var body: some View {
        List {
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

    private func reload() {
        entries = Log.recent.reversed()
    }
}
