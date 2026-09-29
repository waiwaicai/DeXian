import SwiftUI
import Combine

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
    /// 整本离线缓存进度
    @State private var cacheProgress = ChapterCache.Progress()
    private let cacheTicker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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
        .onReceive(cacheTicker) { _ in
            cacheProgress = ChapterCache.shared.progress
        }
        .task {
            // 缓存状态依赖内存里的 meta，进页面时先读一次（后台线程），
            // 否则「已缓存 N 章」永远显示 0。
            if let book = shelf.book(
                origin: searchBook.origin,
                bookUrl: searchBook.bookUrl,
                name: searchBook.name,
                author: searchBook.author
            ) {
                await ChapterCache.shared.loadMeta(bookId: book.id)
            }
            await load()
        }
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
                // 原先只判断 chapters.isEmpty，于是「目录加载失败」也会
                // 一直显示「加载中」—— 用户看到的是永远转不完的假进度，
                // 既不知道失败了、也没法重试。这里按真实状态区分。
                Label(readingButtonTitle, systemImage: readingButtonIcon)
            }
            .buttonStyle(PrimaryButtonStyle(enabled: canStartReading))
            .disabled(!canStartReading)

            Button {
                cacheAll()
            } label: {
                Image(systemName: cacheProgress.isRunning ? "stop.circle" : "arrow.down.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(cacheProgress.isRunning ? Theme.Palette.warning : Theme.Palette.brand)
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
            .disabled(chapters.isEmpty)
            .accessibilityLabel(cacheProgress.isRunning ? "停止缓存" : "缓存整本")

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

    /// 缓存整本：以书架书为单位，未加入书架时先加入
    private func cacheAll() {
        guard let source = sources.source(id: searchBook.origin), !chapters.isEmpty else {
            appState.show("请先加载目录", style: .failure)
            return
        }
        if cacheProgress.isRunning {
            ChapterCache.shared.cancel()
            appState.show("已停止缓存")
            return
        }
        if !isInShelf { addToShelf() }
        guard let book = shelf.book(
            origin: searchBook.origin,
            bookUrl: searchBook.bookUrl,
            name: displayInfo.name,
            author: displayInfo.author
        ) else { return }
        // isCached 现在只读内存里的 meta：必须先把它读进来，
        // 否则「已缓存」全被判成未缓存，点一次缓存整本会把整本书重下一遍。
        Task {
            await ChapterCache.shared.loadMeta(bookId: book.id)
            ChapterCache.shared.cacheAll(
                book: book,
                chapters: chapters,
                source: source,
                variables: book.variable,
                bookInfo: bookInfoMap(displayInfo)
            )
        }
        appState.show("开始缓存整本", style: .success)
    }

    private var isInShelf: Bool {
        shelf.contains(
            bookUrl: searchBook.bookUrl,
            origin: searchBook.origin,
            name: displayInfo.name,
            author: displayInfo.author
        )
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
                Text(chapterEmptyHint)
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

    // MARK: 派生状态

    /// 「开始阅读」按钮的文案：加载中 / 失败 / 可阅读 三态分明
    private var readingButtonTitle: String {
        // 影视源没有「阅读」这个概念，用播放更贴合
        let verb = searchBook.type == .video ? "开始播放" : "开始阅读"
        if !chapters.isEmpty { return verb }
        if isLoading { return "正在获取目录" }
        // 漫画源普遍没有章节目录，整本就是一个阅读页。
        // 这类书源只要拿得到书籍地址就允许进入，由阅读器做单章兜底。
        if canReadWithoutToc { return verb }
        return "目录获取失败"
    }

    private var readingButtonIcon: String {
        let ready = searchBook.type == .video ? "play.rectangle.fill" : "book.fill"
        if !chapters.isEmpty { return ready }
        if isLoading { return ready }
        return canReadWithoutToc ? ready : "exclamationmark.triangle"
    }

    /// 漫画源是否可以在没有目录的情况下直接进入阅读。
    ///
    /// 不能简单地用「地址非空」放行：小说源目录失败时进去只会看到空白，
    /// 反倒让人以为软件坏了。这里只对漫画放行 —— 阅读器侧已有
    /// fallbackToSingleChapter()，会把书籍页本身当成唯一一章解析。
    private var canReadWithoutToc: Bool {
        ReaderEntryPolicy.canOpenWithoutToc(
            type: searchBook.type,
            tocUrl: info?.tocUrl,
            bookUrl: searchBook.bookUrl
        )
    }

    /// 阅读按钮是否可点。
    private var canStartReading: Bool {
        !chapters.isEmpty || canReadWithoutToc
    }

    /// 章节区的空状态文案。
    ///
    /// 漫画源的「没有目录」是正常现象，说成「获取失败」会让人以为软件坏了 ——
    /// 旧版的闪退投诉里有一半是这一步被误导后反复重试造成的。
    private var chapterEmptyHint: String {
        if isLoading { return "正在获取目录…" }
        if canReadWithoutToc {
            return searchBook.type == .video
                ? "该影视源无剧集目录，直接点上方「开始播放」即可"
                : "该漫画源无章节目录，直接点上方「开始阅读」即可"
        }
        return errorMessage == nil ? "暂无章节信息" : "目录获取失败，请点上方「重试」"
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
            // api 型书源（如大量 JSON 接口源）搜索结果的 detailUrl 常为空，
            // 目录直接由接口给出。此时跳过详情页，直接按 tocUrl / bookUrl 取目录，
            // 否则会拿空地址去请求，只能得到一句「地址为空」。
            var detail = BookInfo()
            if !searchBook.bookUrl.trimmed.isEmpty {
                detail = try await engine.bookInfo(bookUrl: searchBook.bookUrl)
            }
            info = detail

            let tocLink = (detail.tocUrl?.trimmed.isEmpty == false ? detail.tocUrl : nil)
                ?? searchBook.bookUrl
            guard !tocLink.trimmed.isEmpty else {
                chapters = []
                errorMessage = "该源未提供书籍地址，无法打开目录"
                isLoading = false
                return
            }
            chapters = try await engine.toc(tocUrl: tocLink, bookInfo: bookInfoMap(detail))
            errorMessage = nil
        } catch {
            // 漫画源普遍不提供章节目录：整本就是一个阅读页。
            // 这不是错误，不该弹「目录获取失败」把人挡在门外，
            // 阅读器会在打开时把书籍页当成唯一一章解析。
            errorMessage = canReadWithoutToc ? nil : SourceError.describe(error)
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
            let id = ShelfBook.identifier(
                origin: searchBook.origin,
                bookUrl: searchBook.bookUrl,
                name: displayInfo.name,
                author: displayInfo.author
            )
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
        var book = shelf.book(
            origin: searchBook.origin,
            bookUrl: searchBook.bookUrl,
            name: displayInfo.name,
            author: displayInfo.author
        ) ?? shelfBook
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
