import SwiftUI

@main
struct DeXianApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var webAuth = WebAuthPresenter.shared

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
                // 书源需要用户过验证 / 登录时弹出网页
                .sheet(item: $webAuth.request) { request in
                    WebAuthView(request: request, presenter: webAuth)
                }
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
