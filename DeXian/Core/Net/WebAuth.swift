import Foundation
import SwiftUI
import WebKit

/// 书源验证窗口。
///
/// 对应 Legado 的 `java.startBrowserAwait(url, title)`：
/// 部分书源需要用户在弹出的网页里手动过验证码 / 登录 / 点一次「继续访问」，
/// 完成后再由书源脚本读取 Cookie 继续抓正文。
///
/// 这里用 WKWebView 打开目标地址，把页面产生的 Cookie 写回该书的 CookieJar，
/// 用户点「完成」后关闭窗口并把 Cookie 交回脚本。
///
/// 注意：所有方法都必须在主线程调用（界面状态只在主线程更新），
/// 因此不标注 @MainActor，避免被非隔离上下文调用时的编译错误。
final class WebAuthPresenter: ObservableObject {
    static let shared = WebAuthPresenter()

    struct Request: Identifiable {
        var id = UUID()
        var url: String
        var title: String
        var sourceKey: String
    }

    @Published var request: Request?
    private var completion: ((String) -> Void)?

    private init() {}

    /// 打开验证窗口；用户完成或取消后回调最终 Cookie。
    /// 同一时刻只允许一个窗口，已有的先以空结果结束，避免脚本互相等待。
    func present(url: String, title: String, sourceKey: String, completion: @escaping (String) -> Void) {
        finish("")
        self.completion = completion
        request = Request(url: url, title: title.isEmpty ? "需要验证" : title, sourceKey: sourceKey)
    }

    /// 用户点「完成」：回传当前页 Cookie
    func complete(cookie: String) { finish(cookie) }

    /// 用户点「取消」
    func cancel() { finish("") }

    private func finish(_ cookie: String) {
        guard let completion else {
            request = nil
            return
        }
        self.completion = nil
        request = nil
        completion(cookie)
    }
}

/// 验证窗口：加载目标页面，用户操作完成后把 Cookie 交回。
struct WebAuthView: View {
    let request: WebAuthPresenter.Request
    @ObservedObject var presenter: WebAuthPresenter

    @State private var cookie: String = ""
    @State private var isLoading = true
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                WebAuthWebView(
                    urlString: request.url,
                    sourceKey: request.sourceKey,
                    cookie: $cookie,
                    isLoading: $isLoading,
                    lastError: $lastError
                )

                if isLoading {
                    VStack(spacing: Theme.Spacing.md) {
                        ProgressView()
                        Text("正在打开验证页面…")
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                    }
                    .padding(Theme.Spacing.xl)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                }

                if let lastError {
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Theme.ColorToken.textTertiary)
                        Text(lastError)
                            .font(.themeCaption)
                            .foregroundStyle(Theme.ColorToken.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Theme.Spacing.xl)
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presenter.cancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presenter.complete(cookie: cookie) }
                        .fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// WKWebView 包装：持续回传 Cookie。
struct WebAuthWebView: UIViewRepresentable {
    let urlString: String
    /// 所属书源 id：验证后的 Cookie 写回该源
    var sourceKey: String = ""
    @Binding var cookie: String
    @Binding var isLoading: Bool
    @Binding var lastError: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // 用默认数据存储，页面登录后的会话能被后续请求复用
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        if let url = URL(string: RuleUtil.sanitizeURL(urlString)) {
            view.load(URLRequest(url: url))
        } else {
            context.coordinator.report("链接无效，无法打开验证页面")
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: WebAuthWebView

        init(_ parent: WebAuthWebView) {
            self.parent = parent
        }

        /// 统一在主线程回写界面状态
        func report(_ message: String?) {
            DispatchQueue.main.async {
                self.parent.lastError = message
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(nil)
            sync(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report("页面加载失败：" + error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report("页面加载失败：" + error.localizedDescription)
        }

        /// 同步当前页面 Cookie，并立刻写回该书的 CookieJar，
        /// 这样脚本后续请求就能带上登录态。
        private func sync(_ webView: WKWebView) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let key = parent.sourceKey
            guard let url = webView.url else { return }
            store.getAllCookies { cookies in
                let header = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
                DispatchQueue.main.async {
                    self.parent.cookie = header
                    guard !key.isEmpty else { return }
                    for item in cookies {
                        CookieJar.shared.setCookie(item.name + "=" + item.value, for: key, url: url)
                    }
                }
            }
        }
    }
}

