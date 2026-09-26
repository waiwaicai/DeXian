import SwiftUI

/// 书籍详情：展示信息、加入书架、查看章节
struct BookDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore

    let searchBook: SearchBook

    @State private var info: BookInfo?
    @State private var chapters: [BookChapter] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var shelfBook: ShelfBook?

    var body: some View {
        ZStack {
            Theme.ColorToken.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    header
                    actionRow

                    if let errorMessage {
                        errorCard(errorMessage)
                    }

                    if let intro = displayInfo.intro, !intro.isEmpty {
                        section(title: "简介", systemImage: "text.alignleft") {
                            Text(intro)
                                .font(.themeCallout)
                                .foregroundStyle(Theme.ColorToken.textSecondary)
                                .lineSpacing(4)
                        }
                    }

                    chapterSection
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.lg)
            }

            if isLoading {
                LoadingView(text: "正在获取详情")
            }
        }
        .navigationTitle(displayInfo.name.isEmpty ? searchBook.name : displayInfo.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var displayInfo: BookInfo {
        let fallback = BookInfo(
            name: searchBook.name,
            author: searchBook.author,
            kind: searchBook.kind,
            wordCount: searchBook.wordCount,
            lastChapter: searchBook.lastChapter,
            intro: searchBook.intro,
            coverUrl: searchBook.coverUrl,
            tocUrl: nil
        )
        guard let info else { return fallback }
        return info.merged(over: fallback)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            CoverImage(url: displayInfo.coverUrl, width: 108, height: 148, cornerRadius: Theme.Radius.md)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(displayInfo.name)
                    .font(.themeTitle2)
                    .foregroundStyle(Theme.ColorToken.textPrimary)
                    .lineLimit(3)

                Text(displayInfo.author.isEmpty ? "佚名" : displayInfo.author)
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textSecondary)

                HStack(spacing: Theme.Spacing.xs) {
                    TagLabel(text: searchBook.originName, color: Theme.Palette.brand)
                    TagLabel(text: searchBook.type.displayName, color: Theme.Palette.accent)
                    if let kind = displayInfo.kind, !kind.isEmpty {
                        TagLabel(text: kind, color: Theme.Palette.success)
                    }
                }

                if let last = displayInfo.lastChapter, !last.isEmpty {
                    Text("最新：" + last)
                        .font(.themeCaption)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                        .lineLimit(2)
                }

                if !chapters.isEmpty {
                    Text("共 " + String(chapters.count) + " 章")
                        .font(.themeCaption)
                        .foregroundStyle(Theme.ColorToken.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 操作

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                startReading()
            } label: {
                Label(chapters.isEmpty ? "加载中" : "开始阅读", systemImage: "book.fill")
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !chapters.isEmpty))
            .disabled(chapters.isEmpty)

            Button {
                toggleShelf()
            } label: {
                Image(systemName: isInShelf ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isInShelf ? Theme.Palette.success : Theme.Palette.brand)
                    .frame(width: 50, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .fill(Theme.ColorToken.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .stroke(Theme.ColorToken.separator, lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var isInShelf: Bool {
        shelf.contains(bookUrl: searchBook.bookUrl, origin: searchBook.origin)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.warning)
            Text(message)
                .font(.themeCaption)
                .foregroundStyle(Theme.ColorToken.textSecondary)
            Spacer(minLength: 0)
            Button("重试") { Task { await load() } }
                .font(.themeCaption)
        }
        .cardStyle(padding: Theme.Spacing.md)
    }

    // MARK: 章节

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "章节", subtitle: chapters.isEmpty ? nil : "最新 20 章",
                          systemImage: "list.bullet.indent")

            if chapters.isEmpty {
                Text("暂无章节信息")
                    .font(.themeCallout)
                    .foregroundStyle(Theme.ColorToken.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.Spacing.xl)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(chapters.suffix(20).enumerated()), id: \.element.id) { _, chapter in
                        HStack {
                            Text(chapter.title)
                                .font(.themeCallout)
                                .foregroundStyle(Theme.ColorToken.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Theme.Spacing.md)
                        .contentShape(Rectangle())
                        .onTapGesture { startReading(at: chapter) }

                        if chapter.id != chapters.suffix(20).last?.id {
                            Divider().background(Theme.ColorToken.separator)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.ColorToken.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.ColorToken.separator, lineWidth: 0.8)
                )
            }
        }
    }

    private func section<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: title, systemImage: systemImage)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(padding: Theme.Spacing.md)
        }
    }

    // MARK: 数据

    private func load() async {
        isLoading = true
        errorMessage = nil
        guard let source = sources.source(id: searchBook.origin) else {
            errorMessage = "书源不存在或已被删除"
            isLoading = false
            return
        }
        let engine = SourceEngine(source: source)

        do {
            let detail = try await engine.bookInfo(bookUrl: searchBook.bookUrl)
            info = detail
            let tocLink = detail.tocUrl ?? searchBook.bookUrl
            chapters = try await engine.toc(tocUrl: tocLink, bookInfo: bookInfoMap(detail))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func bookInfoMap(_ detail: BookInfo) -> [String: String] {
        [
            "name": detail.name.isEmpty ? searchBook.name : detail.name,
            "author": detail.author.isEmpty ? searchBook.author : detail.author,
            "bookUrl": searchBook.bookUrl,
            "tocUrl": detail.tocUrl ?? "",
            "origin": searchBook.origin,
            "originName": searchBook.originName,
            "coverUrl": detail.coverUrl ?? "",
            "intro": detail.intro ?? "",
            "kind": detail.kind ?? ""
        ]
    }

    // MARK: 动作

    private func toggleShelf() {
        if isInShelf {
            let id = searchBook.origin + "|" + searchBook.bookUrl
            shelf.remove(ids: [id])
            appState.show("已移出书架")
            return
        }
        addToShelf()
    }

    private func addToShelf() {
        var book = ShelfBook(search: searchBook, info: displayInfo, tocUrl: info?.tocUrl)
        book.chapters = chapters
        book.totalChapterCount = chapters.count
        if let last = chapters.last { book.latestChapterTitle = last.title }
        if shelf.add(book) {
            shelfBook = book
            appState.show("已加入书架", style: .success)
        }
    }

    private func startReading(at chapter: BookChapter? = nil) {
        if !isInShelf { addToShelf() }
        var book = shelf.book(id: searchBook.origin + "|" + searchBook.bookUrl) ?? shelfBook
        if book == nil {
            var created = ShelfBook(search: searchBook, info: displayInfo, tocUrl: info?.tocUrl)
            created.chapters = chapters
            created.totalChapterCount = chapters.count
            book = created
        }
        guard var target = book else { return }
        target.chapters = chapters
        if let chapter { target.lastReadChapterIndex = chapter.index }
        appState.openReader(target)
    }
}
