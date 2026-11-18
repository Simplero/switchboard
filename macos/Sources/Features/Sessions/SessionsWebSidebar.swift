import AppKit
import SwiftUI
import WebKit

/// The sessions sidebar as a web page served by the session helper
/// (http://127.0.0.1:4477/sidebar). Editing that page reloads it in place, so
/// most sidebar changes need no app restart.
///
/// One web view is shared by all windows and moves into whichever window is in
/// front, so the app holds one page in memory, not one per session window.
/// Clicks, menus, questions and keyboard shortcuts stay native: the page calls
/// the app through `window.webkit.messageHandlers.sessions`.
@MainActor
final class SessionsWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = SessionsWeb()

    let webView: WKWebView
    private var loaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(self, name: "sessions")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:4477/sidebar")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setFocus(SessionsStore.shared.focusedSurfaceID)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { retry() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { retry() }

    private func retry() {
        // The helper may not be up yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.webView.reload() }
    }

    /// Links (artifacts and so on) open in the browser, not inside the sidebar.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: App → page

    func setFocus(_ id: String?) {
        let arg = id.map { "'\($0)'" } ?? "null"
        webView.evaluateJavaScript("window.Sessions && Sessions.setFocus(\(arg))")
    }

    func focusSearch() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.Sessions && Sessions.focusSearch()")
    }

    // MARK: Page → app

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let store = SessionsStore.shared
        switch type {
        case "open":
            guard let k = body["k"] as? String else { return }
            if let s = store.payload?.s.first(where: { $0.k == k }) {
                store.open(s)
            } else {
                store.send(["op": "open", "k": k])
            }
        case "nav":
            store.navOrder = body["keys"] as? [String] ?? []
        case "menu":
            guard let k = body["k"] as? String, let s = store.payload?.s.first(where: { $0.k == k }) else { return }
            showMenu(for: s)
        case "blur":
            // Esc in the search box: give the keyboard back to the terminal.
            if let controller = webView.window?.windowController as? BaseTerminalController,
               let view = controller.focusedSurface {
                webView.window?.makeFirstResponder(view)
            }
        default:
            break
        }
    }

    // MARK: Native right-click menu

    private var menuActions: [() -> Void] = []

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < menuActions.count else { return }
        menuActions[sender.tag]()
    }

    private func item(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        i.target = self
        i.tag = menuActions.count
        i.state = checked ? .on : .off
        menuActions.append(action)
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        parent.submenu = m
        return parent
    }

    private func ask(_ title: String, placeholder: String, initial: String = "", done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { done(v) }
        }
    }

    private func showMenu(for s: SessionItem) {
        let store = SessionsStore.shared
        menuActions = []
        let menu = NSMenu()
        menu.addItem(item(s.isOpen ? "Go to session" : "Reopen here") { store.open(s) })
        if s.isOpen && s.be != "ghostty" {
            menu.addItem(item("Move it here from cmux…") { store.askMove(s) })
        }
        if s.isOpen {
            menu.addItem(item("Park (close it, keep it here)") { store.send(["op": "park", "k": s.k]) })
            menu.addItem(item("Close") { store.send(["op": "close", "k": s.k]) })
        } else if s.isParked {
            menu.addItem(item("Unpark") { store.send(["op": "unpark", "k": s.k]) })
        }
        menu.addItem(item(s.st == "handled" ? "Needs me again" : "Mark as handled") { store.send(["op": "ack", "k": s.k]) })
        menu.addItem(.separator())
        menu.addItem(submenu("Class", (store.payload?.classes ?? []).map { c in
            item(c, checked: s.c == c) { store.send(["op": "cls", "k": s.k, "cls": c]) }
        } + [.separator(), item("New class…") { [weak self] in
            self?.ask("New class", placeholder: "e.g. Infra") { store.send(["op": "cls", "k": s.k, "cls": $0]) }
        }]))
        menu.addItem(submenu("Labels", (store.payload?.labels ?? []).map { l in
            item(l, checked: s.labels.contains(l)) { store.send(["op": "label", "k": s.k, "label": l]) }
        } + [.separator(), item("New label…") { [weak self] in
            self?.ask("New label", placeholder: "e.g. later") { store.send(["op": "label", "k": s.k, "label": $0]) }
        }]))
        menu.addItem(item("Rename…") { [weak self] in
            self?.ask("Rename session", placeholder: "Name", initial: s.n) { store.send(["op": "rename", "k": s.k, "name": $0]) }
        })
        if s.isOpen, let replies = s.rp?.filter({ $0.count >= 2 }), !replies.isEmpty {
            menu.addItem(submenu("Reply", replies.map { r in item(r[0]) { store.send(["op": "send", "k": s.k, "text": r[1]]) } }))
        }
        if let arts = s.art, !arts.isEmpty {
            menu.addItem(submenu("Artifacts", arts.map { u in
                item("Open " + (u.split(separator: "/").last.map(String.init) ?? u)) {
                    if let url = URL(string: u) { NSWorkspace.shared.open(url) }
                }
            }))
        }
        menu.addItem(submenu("Switch login", ["~/.claude", "~/.claude-ccl", "~/.claude-ccm"].map { d in
            item(store.payload?.spares?[d]?.lg ?? d, checked: s.ld == d) {
                if s.ld != d { store.send(["op": "switch", "k": s.k, "login": d]) }
            }
        }))
        if !s.isOpen {
            menu.addItem(.separator())
            menu.addItem(item("Remove from list") { store.send(["op": "forget", "k": s.k]) })
        }
        let point = webView.convert(webView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: point, in: webView)
    }
}

/// Holds the shared web view for one window. When that window comes to the
/// front, the web view moves into it.
final class SessionsWebHolder: NSView {
    private var observer: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.adopt() }
        }
        if window.isKeyWindow || SessionsWeb.shared.webView.superview == nil { adopt() }
    }

    @MainActor func adopt() {
        let web = SessionsWeb.shared.webView
        SessionsWeb.shared.loadIfNeeded()
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

struct SessionsWebSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> SessionsWebHolder { SessionsWebHolder() }
    func updateNSView(_ nsView: SessionsWebHolder, context: Context) {}
}
