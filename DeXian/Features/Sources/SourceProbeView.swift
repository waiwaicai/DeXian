import SwiftUI

/// 书源探测：批量试出哪些源还能用，并一键清掉失效的。
///
/// 上千个书源里大部分早就失效了，但用户没有任何办法分辨 ——
/// 只能一个个点开试，或者忍受每轮搜索都要等那些死源超时。
/// 这一页把「试」自动化：跑一轮，把能用的、不能用的分开列出来。
struct SourceProbeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore

    @StateObject private var model = SourceProbeViewModel()
    @State private var showCleanConfirm = false

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            List {
                keywordSection
                statusSection
                listSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("书源探测")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("清除失效书源", isPresented: $showCleanConfirm) {
            Button("清除 " + String(model.removableCount) + " 个", role: .destructive) {
                let ids = model.removableIDs()
                sources.remove(ids: ids)
                model.removeLocally(ids: ids)
                appState.show("已清除 " + String(ids.count) + " 个失效书源", style: .success)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除确定失效的书源（站点已下线、规则已失效）。\n"
                 + "网络异常、超时、需要登录，以及你自己禁用的源都会保留。\n"
                 + "此操作不可撤销，建议先在书源管理里导出备份。")
        }
    }

    // MARK: 关键词

    private var keywordSection: some View {
        Section {
            HStack {
                TextField("探测关键词", text: $model.keyword)
                    .font(.themeBody)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .disabled(model.isRunning)
                Spacer()
                Button("开始探测") { model.start(sources: sources.sources) }
                    .font(.themeCallout)
                    .disabled(model.isRunning || sources.sources.isEmpty)
            }
        } header: {
            Text("探测关键词")
        } footer: {
            Text("用这个关键词逐个搜索书源，能搜到书即视为可用。默认用高频书名，冷门站点可改成更通用的词。")
        }
    }

    // MARK: 进度

    @ViewBuilder
    private var statusSection: some View {
        if model.totalCount > 0 {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack {
                        Text(model.isRunning ? "正在探测" : "探测完成")
                            .font(.themeCallout.bold())
                        Spacer()
                        Text(String(model.finishedCount) + " / " + String(model.totalCount))
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                            .monospacedDigit()
                    }

                    if model.isRunning {
                        ProgressView(
                            value: Double(model.finishedCount),
                            total: Double(max(model.totalCount, 1))
                        )
                        .tint(Theme.Palette.brand)
                    }

                    HStack(spacing: Theme.Spacing.lg) {
                        countChip("可用", value: model.validCount, color: Theme.Palette.success)
                        countChip("失效", value: model.invalidCount, color: Theme.Palette.warning)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)

                Toggle("只看失效", isOn: $model.onlyInvalid)
                    .font(.themeBody)
                    .tint(Theme.Palette.brand)
            } header: {
                Text("结果")
            } footer: {
                if model.removableCount > 0 {
                    Text("有 " + String(model.removableCount) + " 个书源探测失败，可以一键清除。")
                } else if !model.isRunning {
                    Text("没有发现可清除的失效书源。若有不少源显示超时，通常是当前网络问题，换个网络再试。")
                }
            }
        }
    }

    private func countChip(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.themeCaption)
            Text(String(value))
                .font(.themeCaptionBold)
                .monospacedDigit()
        }
        .foregroundStyle(Theme.ColorToken.textSecondary)
    }

    // MARK: 列表

    @ViewBuilder
    private var listSection: some View {
        if model.totalCount > 0 {
            Section {
                let rows = model.visibleItems
                if rows.isEmpty, !model.isRunning {
                    Text(model.onlyInvalid ? "没有失效书源" : "没有书目")
                        .font(.themeCallout)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                }
                ForEach(rows) { item in
                    ProbeRow(item: item)
                        .listRowBackground(Theme.ColorToken.surface)
                }
                if model.hasMore {
                    Button("显示更多") { model.loadMore() }
                        .font(.themeCallout)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("书源")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if model.isRunning {
                Button("停止") { model.cancel() }
                    .font(.themeCallout)
            } else if model.removableCount > 0 {
                Button("清除失效", role: .destructive) { showCleanConfirm = true }
                    .font(.themeCallout)
            }
        }
    }
}

/// 单行探测结果
private struct ProbeRow: View {
    let item: SourceProbeViewModel.Item

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: item.type.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ColorToken.textTertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.themeBody)
                    .lineLimit(1)
                if let state = item.state {
                    Text(state.displayText)
                        .font(.themeTiny)
                        .foregroundStyle(color(for: state))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if item.isLoading {
                ProgressView().controlSize(.mini)
            } else if let state = item.state {
                Image(systemName: state.isValid ? "checkmark.circle.fill" : statusIcon(for: state))
                    .font(.system(size: 15))
                    .foregroundStyle(color(for: state))
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for state: SourceProbe.State) -> Color {
        if state.isValid { return Theme.Palette.success }
        if case .skipped = state { return Theme.ColorToken.textTertiary }
        return Theme.Palette.warning
    }

    private func statusIcon(for state: SourceProbe.State) -> String {
        if case .skipped = state { return "minus.circle" }
        return "xmark.circle.fill"
    }
}
