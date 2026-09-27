import SwiftUI

@main
struct DeXianApp: App {
    init() {
        // 最早时机安装崩溃捕获：越早越好，启动阶段的闪退也能留下现场。
        FileStorage.prepareDirectory()
        CrashReporter.install()
    }

    @StateObject private var appState = AppState()
    @StateObject private var webAuth = WebAuthPresenter.shared

    /// 用于在进入后台时把待写数据落盘
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.sources)
                .environmentObject(appState.rss)
                .environmentObject(appState.shelf)
                .environmentObject(appState.settings)
                .preferredColorScheme(appState.settings.appearance.colorScheme)
                .tint(Theme.Palette.brand)
                // 写盘有 300ms 合并窗口；被挂起前必须刷一次，否则改动会丢
                .onChange(of: scenePhase) { phase in
                    guard phase != .active else {
                        CrashReporter.beginSession()
                        return
                    }
                    appState.flushPendingWrites()
                    // 进后台就清掉运行标记。
                    // iOS 会常态地回收后台应用，那是正常行为。
                    // 不清标记的话，每次从后台回来都会误报「上次被强杀」。
                    // 标记只在前台时保留，而前台被杀正是闪退。
                    if phase == .background { CrashReporter.endSession() }
                }
                // 书源需要用户过验证 / 登录时弹出网页
                .sheet(item: $webAuth.request) { request in
                    WebAuthView(request: request, presenter: webAuth)
                }
                // 启动完成后标记「本次运行开始」：
                // 下次启动若发现标记还在，就说明上次是被系统强杀的
                //（内存超限或看门狗），这类崩溃不会留下崩溃报告。
                .onAppear { CrashReporter.beginSession() }
        }
    }
}

/// 根视图：四个标签页 + 统一导航样式
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var shelf: ShelfStore

    enum Tab: Hashable {
        case shelf, explore, rss, search, settings
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $appState.selectedTab) {
                NavigationStack { ShelfView() }
                    .tabItem { Label("书架", systemImage: "books.vertical.fill") }
                    .tag(Tab.shelf)

                NavigationStack { ExploreView() }
                    .tabItem { Label("发现", systemImage: "safari.fill") }
                    .tag(Tab.explore)

                NavigationStack { RssHomeView() }
                    .tabItem { Label("订阅", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(Tab.rss)

                NavigationStack { SearchView() }
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(Tab.search)

                NavigationStack { SettingsView() }
                    .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                    .tag(Tab.settings)
            }

            if let toast = appState.toast {
                ToastView(message: toast)
                    .padding(.top, Theme.Spacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.22), value: appState.toast)
        .fullScreenCover(item: $appState.readingBook) { book in
            NavigationStack {
                ReaderView(book: book, source: sources.source(id: book.origin), shelf: shelf)
            }
        }
    }
}
