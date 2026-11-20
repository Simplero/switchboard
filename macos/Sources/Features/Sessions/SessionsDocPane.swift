import AppKit
import SwiftUI
import WebKit

/// A page next to a session: a Simplero Doc you click in the panel (or ⌘-click in the terminal)
/// opens on the right of the terminal, beside the work it belongs to, instead of in another
/// browser tab. One page per session; it stays while you switch sessions and comes back with
/// the session. "Open in browser" sends it to your browser as before.
@MainActor
final class SessionsDocPanes: ObservableObject {
    static let shared = SessionsDocPanes()

    /// Session id (TerminalController.sessionsWorkspace) → its page.
    @Published private(set) var pages: [String: DocPage] = [:]
    /// The first page of this run signs the pane in with the Mac's Simplero sign-in (Phone Link).
    private var signedIn = false

    /// Simplero Docs: the share host, and Docs in the admin.
    nonisolated static func isDoc(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "doc.simplero.me" { return true }
        return (host == "simplero.com" || host.hasSuffix(".simplero.com")) && url.path.hasPrefix("/admin/docs")
    }

    /// Pages that stay in the pane when you click on (Simplero itself); others open in your browser.
    nonisolated static func staysInPane(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return isDoc(url) || host == "simplero.com" || host.hasSuffix(".simplero.com") || host.hasSuffix(".simplero.me")
    }

    func open(_ url: URL, session ws: String) {
        let page = pages[ws] ?? DocPage()
        pages[ws] = page
        Task {
            let target = await signInURL(for: url)
            page.load(target)
        }
    }

    func close(session ws: String) {
        pages[ws]?.webView.stopLoading()
        pages[ws] = nil
    }

    /// The session of the window in front, if it is a session window.
    static var frontSession: String? {
        (NSApp.keyWindow?.windowController as? TerminalController)?.sessionsWorkspace
    }

    /// Once per run: a one-time sign-in link to the page, made with the Mac's Simplero sign-in
    /// (the same as the phone's in-app pages). Without a sign-in, the page itself.
    private func signInURL(for url: URL) async -> URL {
        guard !signedIn, let key = SBAccount.shared.mobileKey else { return url }
        var req = URLRequest(url: URL(string: SBAccount.server + "/api/mobile/v1/users/generate_auto_login_url")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["return_to": url.absoluteString])
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = j["url"] as? String, let signed = URL(string: s) else { return url }
        signedIn = true
        return signed
    }
}

/// One page in the pane, with its own history.
@MainActor
final class DocPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // stays signed in between runs
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            webView.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.loading = w.isLoading } },
        ]
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    /// Simplero pages stay here; a link to anywhere else opens in your browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? ""), !SessionsDocPanes.staysInPane(url) {
            SessionsLinkOpener.open(url, nextToSession: false)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// A link that wants a new window: a Simplero page here, anything else in your browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if SessionsDocPanes.staysInPane(url) { webView.load(URLRequest(url: url)) } else { SessionsLinkOpener.open(url, nextToSession: false) }
        }
        return nil
    }
}

/// The pane: a small bar (back, forward, reload, title, open in browser, close) over the page.
struct DocPaneView: View {
    @ObservedObject var page: DocPage
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                bar("chevron.left", "Back") { page.webView.goBack() }.disabled(!page.canGoBack)
                bar("chevron.right", "Forward") { page.webView.goForward() }.disabled(!page.canGoForward)
                bar(page.loading ? "xmark" : "arrow.clockwise", page.loading ? "Stop" : "Reload") {
                    if page.loading { page.webView.stopLoading() } else { page.webView.reload() }
                }
                Text(page.title.isEmpty ? (page.webView.url?.host ?? "") : page.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .help(page.webView.url?.absoluteString ?? "")
                bar("arrow.up.right.square", "Open in your browser") {
                    if let u = page.webView.url { SessionsLinkOpener.open(u, nextToSession: false) }
                }
                bar("xmark.circle", "Close this page", action: close)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            Divider()
            DocWebHolderView(page: page)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func bar(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Holds the page's web view in one window. A session's tabs are separate windows, so the web
/// view moves into the one in front (like the sidebar).
struct DocWebHolderView: NSViewRepresentable {
    let page: DocPage
    func makeNSView(context: Context) -> DocWebHolder { DocWebHolder(page: page) }
    func updateNSView(_ nsView: DocWebHolder, context: Context) { nsView.page = page; nsView.adoptIfFront() }
}

final class DocWebHolder: NSView {
    var page: DocPage
    private var observer: Any?

    init(page: DocPage) {
        self.page = page
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.adopt() }
        }
        adoptIfFront()
    }

    @MainActor func adoptIfFront() {
        guard let window else { return }
        if window.isKeyWindow || page.webView.superview == nil { adopt() }
    }

    @MainActor func adopt() {
        let web = page.webView
        guard web.superview !== self else { return }
        web.removeFromSuperview()
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        addSubview(web)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
