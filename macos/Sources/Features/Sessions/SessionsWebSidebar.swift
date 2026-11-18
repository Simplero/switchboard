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
final class SessionsWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate, ObservableObject {
    /// The sidebar page.
    static let shared = SessionsWeb(path: "sidebar")
    /// The banner above the terminal: this session, its login, what it needs, and its tabs.
    static let banner = SessionsWeb(path: "banner")

    let webView: WKWebView
    let path: String
    private var loaded = false
    /// Height the banner page reports, so its frame fits.
    @Published var height: CGFloat = 64

    init(path: String) {
        self.path = path
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
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:4477/\(path)")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if path == "sidebar" { setFocus(SessionsStore.shared.focusedSurfaceID) } else { pushBannerContext() }
    }

    // MARK: Banner context (which window, its terminals, its tabs, update)

    private var lastContext = ""

    /// Tell the banner which session window is in front, its terminals and tabs.
    func pushBannerContext() {
        guard path == "banner" else { return }
        let key = NSApp.keyWindow?.windowController is BaseTerminalController ? NSApp.keyWindow : nil
        let controller = key?.windowController as? BaseTerminalController
        let surfaces = controller?.surfaceTree.root?.leaves().map { $0.id.uuidString } ?? []
        var tabs: [[String: Any]] = []
        if let key, let group = key.tabGroup, group.windows.count > 1 {
            // Tabs live in the banner. TerminalWindow hides the macOS tab bar.
            for w in group.windows {
                tabs.append(["id": w.windowNumber, "title": w.title, "selected": w === group.selectedWindow])
            }
        }
        var ctx: [String: Any] = ["surfaces": surfaces, "tabs": tabs]
        let v = SessionsVersion.shared
        if v.updateAvailable { ctx["update"] = ["running": v.runningBuild, "installed": v.installedBuild] }
        guard let data = try? JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        if json == lastContext { return }
        lastContext = json
        webView.evaluateJavaScript("window.Banner && Banner.setContext(\(json))")
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
        case "height":
            if let h = body["h"] as? Double, abs(CGFloat(h) - height) > 0.5 { height = CGFloat(h) }
        case "switchLogin":
            guard let k = body["k"] as? String, let login = body["login"] as? String else { return }
            store.send(["op": "switch", "k": k, "login": login])
        case "op":
            if let o = body["o"] as? [String: Any] { store.send(o) }
        case "restartUpdate":
            SessionsVersion.shared.restart()
        case "selectTab":
            guard let id = body["id"] as? Int, let w = NSApp.window(withWindowNumber: id) else { return }
            w.tabGroup?.selectedWindow = w
            w.makeKeyAndOrderFront(nil)
            lastContext = ""
            pushBannerContext()
        case "newTab":
            guard let appDelegate = NSApp.delegate as? AppDelegate, let key = NSApp.keyWindow else { return }
            _ = TerminalController.newTab(appDelegate.ghostty, from: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.lastContext = ""; self.pushBannerContext() }
        case "closeTab":
            guard let id = body["id"] as? Int, let w = NSApp.window(withWindowNumber: id) else { return }
            w.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.lastContext = ""; self.pushBannerContext() }
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
            menu.addItem(item("Open here with another login…") { store.askMove(s) })
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
    var page: SessionsWeb = .shared

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.adopt() }
        }
        if window.isKeyWindow || page.webView.superview == nil { adopt() }
    }

    @MainActor func adopt() {
        let web = page.webView
        page.loadIfNeeded()
        if page.path == "banner" { page.pushBannerContext() }
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
    var page: SessionsWeb = .shared
    func makeNSView(context: Context) -> SessionsWebHolder {
        let h = SessionsWebHolder()
        h.page = page
        return h
    }
    func updateNSView(_ nsView: SessionsWebHolder, context: Context) {}
}
