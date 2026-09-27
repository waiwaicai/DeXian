import SwiftUI

/// 书架：网格布局 + 分组筛选 + 长按管理
struct ShelfView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var shelf: ShelfStore

    @State private var selectedGroupId: String?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    /// 右上角「+」：跳到书源导入（原先只置了 showImport 却没绑定任何弹窗，点了没反应）
    @State private var showImport = false
    @State private var showSearch = false
    @State private var showGroupSheet = false

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 150), spacing: Theme.Spacing.lg)
    ]

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            if shelf.books.isEmpty {
                EmptyStateView(
                    systemImage: "books.vertical",
                    title: "书架还空着",
                    message: "去“搜索”或“发现”里添加喜欢的书；\n也可以先在“我的 → 书源管理”导入书源。",
                    actionTitle: "去搜索",
                    action: { appState.selectedTab = .search }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        if !shelf.groups.isEmpty {
                            groupFilter
                        }
                        bookGrid
                    }
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.vertical, Theme.Spacing.md)
                }
            }
        }
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .sheet(isPresented: $showGroupSheet) { groupSheet }
        .sheet(isPresented: $showImport) {
            NavigationStack {
                ImportSourceView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("完成") { showImport = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            NavigationStack {
                SearchView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("完成") { showSearch = false }
                        }
                    }
            }
        }
    }

    // MARK: 分组筛选

    private var groupFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                groupChip(title: "全部", isActive: selectedGroupId == nil) {
                    selectedGroupId = nil
                }
                ForEach(shelf.groups) { group in
                    groupChip(title: group.name, isActive: selectedGroupId == group.id) {
                        selectedGroupId = group.id
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    private func groupChip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.themeCallout)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? .white : Theme.ColorToken.textSecondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    Capsule().fill(isActive ? Theme.Palette.brand : Theme.ColorToken.surface)
                )
                .overlay(
                    Capsule().stroke(isActive ? Color.clear : Theme.ColorToken.separator, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 网格

    private var visibleBooks: [ShelfBook] {
        shelf.books(inGroup: selectedGroupId)
    }

    private var bookGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.lg) {
            ForEach(visibleBooks) { book in
                ShelfBookCell(
                    book: book,
                    isSelecting: isSelecting,
                    isSelected: selection.contains(book.id)
                )
                .onTapGesture {
                    if isSelecting {
                        toggleSelection(book.id)
                    } else {
                        appState.openReader(book)
                    }
                }
                .contextMenu {
                    if !isSelecting {
                        Button {
                            appState.openReader(book)
                        } label: { Label("开始阅读", systemImage: "book") }

                        Button {
                            shelf.moveToTop(id: book.id)
                        } label: { Label("置顶", systemImage: "arrow.up.to.line") }

                        Button(role: .destructive) {
                            shelf.remove(ids: [book.id])
                        } label: { Label("移出书架", systemImage: "trash") }
                    }
                }
            }
        }
    }

    // MARK: 底部批量操作

    private var selectionBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button {
                if selection.count == visibleBooks.count {
                    selection.removeAll()
                } else {
                    selection = Set(visibleBooks.map { $0.id })
                }
            } label: {
                Text(selection.count == visibleBooks.count ? "取消全选" : "全选")
                    .font(.themeCallout)
            }

            Spacer()

            Button {
                showGroupSheet = true
            } label: {
                Label("分组", systemImage: "folder")
                    .font(.themeCallout)
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                shelf.remove(ids: selection)
                selection.removeAll()
                isSelecting = false
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.themeCallout)
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
    }

    private var groupSheet: some View {
        NavigationStack {
            List {
                Section("添加到分组") {
                    ForEach(shelf.groups) { group in
                        Button {
                            shelf.assign(bookIds: selection, toGroup: group.id)
                            showGroupSheet = false
                            isSelecting = false
                            selection.removeAll()
                        } label: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.textTertiary)
                            }
                        }
                    }
                }
                Section {
                    Button("移出分组") {
                        shelf.assign(bookIds: selection, toGroup: nil)
                        showGroupSheet = false
                        isSelecting = false
                        selection.removeAll()
                    }
                }
            }
            .navigationTitle("选择分组")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !shelf.books.isEmpty {
                Button(isSelecting ? "完成" : "管理") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isSelecting.toggle()
                        selection.removeAll()
                    }
                }
                .font(.themeCallout)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showSearch = true
                } label: {
                    Label("搜索添加", systemImage: "magnifyingglass")
                }
                Button {
                    showImport = true
                } label: {
                    Label("导入书源", systemImage: "square.and.arrow.down")
                }
                Button {
                    appState.selectedTab = .settings
                } label: {
                    Label("书源管理", systemImage: "list.bullet")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

/// 书架单元格
struct ShelfBookCell: View {
    let book: ShelfBook
    var isSelecting: Bool
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack(alignment: .topTrailing) {
                CoverImage(url: book.coverUrl, width: 110, height: 150, cornerRadius: Theme.Radius.md)

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.Palette.brand : .white)
                        .background(Circle().fill(.black.opacity(0.28)).frame(width: 20, height: 20))
                        .padding(Theme.Spacing.sm)
                }

                if book.lastReadTime != nil, book.totalChapterCount > 0 {
                    progressBadge
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .font(.themeCallout)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(book.author.isEmpty ? "佚名" : book.author)
                    .font(.themeTiny)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(isSelecting && !isSelected ? 0.75 : 1)
    }

    private var progressBadge: some View {
        let total = max(book.totalChapterCount, 1)
        let ratio = min(Double(book.lastReadChapterIndex + 1) / Double(total), 1)
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.35), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(Theme.Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .background(Circle().fill(.black.opacity(0.32)))
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
