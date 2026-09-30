import SwiftUI

/// 发现页：按书源分类浏览
struct ExploreView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore

    @StateObject private var viewModel = ExploreViewModel()

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            if sources.exploreSources.isEmpty {
                EmptyStateView(
                    systemImage: "safari",
                    title: "没有可用的发现源",
                    message: "书源需要支持“发现”功能。\n请到“我的 → 书源管理”导入并启用带发现的书源。"
                )
            } else {
                VStack(spacing: 0) {
                    sourcePicker
                    if !viewModel.controls.isEmpty { formPanel }
                    if !viewModel.categories.isEmpty { categoryPicker }
                    bookList
                }
            }
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.selectedSourceId == nil,
               let first = sources.exploreSources.first {
                await viewModel.select(source: first)
            }
        }
        .onAppear {
            // 表单按钮要求搜索时：切到搜索页并立刻搜索
            viewModel.requestSearch = { keyword in
                appState.searchKeyword = keyword
                appState.selectedTab = .search
            }
            viewModel.toast = { text in appState.show(text) }
        }
    }

    // MARK: 表单控件

    /// 表单型发现源（七猫 · API / 奈飞工厂 / 听小说APP / 吉站漫画 …）的
    /// 下拉框与按钮。这些源的可选分类只有执行脚本才知道，
    /// 所以控件必须能真的驱动一次求值。
    private var formPanel: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // 文本输入：按钮脚本靠 infoMap['关键字'] 取词，
            // 没有输入框的话「🔍搜索」永远提示「请输入关键字」。
            ForEach(viewModel.textControls) { control in
                TextField(control.title, text: Binding(
                    get: { viewModel.controlValues[control.title] ?? "" },
                    set: { viewModel.controlValues[control.title] = $0 }
                ))
                .font(.themeCallout)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.ColorToken.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.ColorToken.separator, lineWidth: 0.8)
                )
                .padding(.horizontal, Theme.Spacing.page)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(viewModel.actionControls) { control in
                        if control.isButton {
                            Button {
                                Task { await viewModel.perform(control: control) }
                            } label: {
                                Text(control.title)
                                    .font(.themeCaption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, Theme.Spacing.md)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(Theme.Palette.accent)
                                    )
                            }
                            .buttonStyle(.plain)
                        } else if control.isSelect, !control.chars.isEmpty {
                            Menu {
                                ForEach(control.chars, id: \.self) { option in
                                    Button(option) {
                                        Task { await viewModel.perform(control: control, value: option) }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(control.title + "：" + (viewModel.controlValues[control.title] ?? ""))
                                        .font(.themeCaption)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundStyle(Theme.Palette.brand)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(Theme.Palette.brand.opacity(0.13))
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
            }
            .frame(height: 34)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: 书源选择

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(sources.exploreSources) { source in
                    Button {
                        Task { await viewModel.select(source: source) }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: source.type.iconName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(source.name)
                                .font(.themeCaption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(viewModel.selectedSourceId == source.id
                                         ? .white : Theme.ColorToken.textSecondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            Capsule().fill(viewModel.selectedSourceId == source.id
                                           ? Theme.Palette.brand : Theme.ColorToken.surface)
                        )
                        .overlay(
                            Capsule().stroke(viewModel.selectedSourceId == source.id
                                             ? Color.clear : Theme.ColorToken.separator, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    // MARK: 分类

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(viewModel.categories) { category in
                    Button {
                        Task { await viewModel.select(category: category) }
                    } label: {
                        Text(category.title ?? "分类")
                            .font(.themeCaption)
                            .fontWeight(viewModel.selectedCategoryId == category.id ? .semibold : .regular)
                            .foregroundStyle(viewModel.selectedCategoryId == category.id
                                             ? Theme.Palette.brand : Theme.ColorToken.textSecondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(viewModel.selectedCategoryId == category.id
                                               ? Theme.Palette.brand.opacity(0.13)
                                               : Theme.ColorToken.surfaceSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.md)
        }
    }

    // MARK: 列表

    private var bookList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.lg) {
                if viewModel.isLoading, viewModel.books.isEmpty {
                    LoadingView(text: "正在加载")
                        .padding(.top, Theme.Spacing.xxl)
                } else if let error = viewModel.errorMessage, viewModel.books.isEmpty {
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "加载失败",
                        message: error,
                        actionTitle: "重试",
                        action: { Task { await viewModel.reload() } }
                    )
                } else if viewModel.books.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "该分类暂无内容",
                        message: "换一个分类试试"
                    )
                } else {
                    ForEach(viewModel.books) { book in
                        NavigationLink {
                            BookDetailView(searchBook: book)
                        } label: {
                            SearchBookRow(book: book)
                                .cardStyle(padding: Theme.Spacing.md)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if book.id == viewModel.books.last?.id {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    }

                    if viewModel.isLoading {
                        ProgressView().padding(.vertical, Theme.Spacing.lg)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }
}

/// 发现页状态
@MainActor
final class ExploreViewModel: ObservableObject {

    @Published private(set) var categories: [ExploreCategory] = []
    /// 表单型发现源（七猫 · API / 奈飞工厂 / 听小说APP …）的下拉框与按钮。
    @Published private(set) var controls: [ExploreFormItem] = []
    /// 控件当前选中的值（title -> 值），提交按钮时按名字取回
    @Published var controlValues: [String: String] = [:]
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var selectedSourceId: String?
    @Published private(set) var selectedCategoryId: String?

    private var source: BookSource?
    private var currentCategory: ExploreCategory?
    private var page = 1
    private var isFinished = false
    /// 是否正在重新求值「发现配置」（防止脚本回调造成递归）
    private var isReloading = false
    /// 是否已经为当前源做过「提交控件默认值」引导（每个源只做一次）
    private var didBootstrap = false

    /// 表单按钮要求「搜索这本书」时，把关键词交给外层切到搜索页
    var requestSearch: ((String) -> Void)?
    /// 表单脚本的 java.toast 提示
    var toast: ((String) -> Void)?

    /// 需要输入框的控件（type = text）
    var textControls: [ExploreFormItem] {
        controls.filter { !$0.isButton && !$0.isSelect }
    }
    /// 按钮与下拉框
    var actionControls: [ExploreFormItem] {
        controls.filter { $0.isButton || $0.isSelect }
    }

    /// 执行某个表单控件的 action（按钮点击 / 下拉框变化）。
    ///
    /// 脚本里会读 `infoMap['控件名']` 拿到用户当前选的值，因此先把
    /// controlValues 灌进 infoMap，再跑 action；action 里若调用
    /// java.refreshExplore()，会经由引擎回调触发 refreshFromForm()。
    func perform(control: ExploreFormItem, value: String? = nil) async {
        guard let source else { return }
        if let value { controlValues[control.title] = value }
        guard let action = control.action, !action.trimmed.isEmpty else {
            // 没有 action 的下拉框：只更新选中值，等用户点提交按钮
            return
        }
        let engine = SourceEngine(source: source)
        engine.onRefreshExplore = { [weak self] in
            Task { @MainActor in await self?.refreshFromForm() }
        }
        engine.onSearchBook = { [weak self] keyword in
            Task { @MainActor in self?.requestSearch?(keyword) }
        }
        engine.onToast = { [weak self] text in
            Task { @MainActor in self?.toast?(text) }
        }
        // action 执行前把控件值写进 infoMap（脚本全部通过它读值）
        let values = controlValues
        await Background.run {
            _ = engine.evaluateFormAction(action, values: values)
        }
    }

    /// 表单要求刷新：重新求值发现配置，但保留用户已选的值。
    func refreshFromForm() async {
        // 防重入：脚本在求值期里再次触发 refreshExplore 时，
        // 无限递归会把发现页卡死。
        guard !isReloading else { return }
        let saved = controlValues
        await reloadCategories()
        for (key, value) in saved where controlValues[key] != nil {
            controlValues[key] = value
        }
    }

    func select(source: BookSource) async {
        self.source = source
        selectedSourceId = source.id
        didBootstrap = false
        await reloadCategories()
        books = []
        errorMessage = nil
        isFinished = false
        page = 1

        if let first = categories.first {
            await select(category: first)
        }
    }

    /// 重新求值「发现配置」（分类 + 表单控件）。
    ///
    /// 脚本型 exploreUrl 必须在这里执行：表单控件的默认值、以及「切换频道」
    /// 之后的新分类列表都由脚本现算。旧实现只做纯文本解析，
    /// 这类源在发现页只能是空白。
    func reloadCategories() async {
        guard let source else { return }
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        await evaluateConfig(source: source)

        // 一次引导：少数源的分类要等控件默认值先提交才会产生。
        //
        // 米读小说的 exploreUrl 只先吐出「频道」下拉框，分类列表是在
        // 频道切换的 action 里（java.refreshExplore）才生成的；
        // 终极全栖接口聚合同理，要先确定用哪个接口。
        // 不做这一步的话，用户切到这些源只会看到一片空白。
        if categories.isEmpty, !didBootstrap, !controls.isEmpty {
            didBootstrap = true
            if let seed = controls.first(where: {
                !$0.isButton && !($0.action ?? "").trimmed.isEmpty
            }) {
                await perform(control: seed, value: controlValues[seed.title])
                didBootstrap = true
                await evaluateConfig(source: source)
            }
        }
    }

    /// 求值一次「发现配置」，写回 categories / controls / controlValues。
    private func evaluateConfig(source: BookSource) async {
        let engine = SourceEngine(source: source)
        engine.onRefreshExplore = { [weak self] in
            Task { @MainActor in await self?.refreshFromForm() }
        }
        engine.onSearchBook = { [weak self] keyword in
            Task { @MainActor in self?.requestSearch?(keyword) }
        }
        engine.onToast = { [weak self] text in
            Task { @MainActor in self?.toast?(text) }
        }
        // 脚本求值可能发网络请求，必须移出主线程，
        // 否则发现页切源时会明显卡住（上一版卡顿投诉的一部分）。
        let page = await Background.run { engine.explorePage() }
        let parsed = page.categories
        // 分类去重：上报的书源里同一分类偶尔重复出现，
        // SwiftUI 的 ForEach 遇到重复 id 会直接 fatalError 崩溃。
        var seenCategory = Set<String>()
        categories = parsed.filter { seenCategory.insert($0.id).inserted }
        // 控件同样去重：同名控件（七猫有多个「分类」性质的按钮）
        // 会撞 id，SwiftUI 的 ForEach 遇到重复 id 直接崩溃。
        var seenControl = Set<String>()
        controls = page.controls.filter { seenControl.insert($0.id).inserted }
        // 控件初值：书源声明的 default，没有就用第一个候选项
        var values: [String: String] = [:]
        for control in controls where !control.isButton {
            if let value = control.defaultValue, !value.isEmpty {
                values[control.title] = value
            } else if let first = control.chars.first {
                values[control.title] = first
            }
        }
        controlValues = values
    }

    func select(category: ExploreCategory) async {
        selectedCategoryId = category.id
        currentCategory = category
        books = []
        page = 1
        isFinished = false
        await loadPage(reset: true)
    }

    func reload() async {
        await loadPage(reset: true)
    }

    func loadMore() async {
        guard !isLoading, !isFinished else { return }
        page += 1
        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        guard let source, let category else { return }
        guard let url = category.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "该分类没有可用地址"
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        let engine = SourceEngine(source: source)
        do {
            let result = try await engine.explore(urlTemplate: url, page: page)
            if result.isEmpty {
                isFinished = true
            }
            if reset {
                books = dedupe(result)
            } else {
                books = dedupe(books + result)
            }
            errorMessage = nil
        } catch {
            errorMessage = SourceError.describe(error)
            isFinished = true
        }
    }

    private var category: ExploreCategory? { currentCategory }

    /// 结果去重。
    ///
    /// 书源分页偶尔会重复返回同一本书，SwiftUI 的 ForEach 遇到重复 id
    /// 会直接 fatalError 崩溃，所以入列表前必须去重。
    private func dedupe(_ list: [SearchBook]) -> [SearchBook] {
        var seen = Set<String>()
        var output: [SearchBook] = []
        for book in list where seen.insert(book.id).inserted {
            output.append(book)
        }
        return output
    }

}
