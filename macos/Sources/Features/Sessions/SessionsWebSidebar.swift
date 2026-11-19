import AppKit
import SwiftUI
import WebKit

/// The sessions sidebar and the panel above the terminal, as two web pages shipped
/// in the app (Pages/switchboard-sidebar.html, Pages/switchboard-panel.html). The
/// session tracker (Switchboard) sends them the sessions; they ask it to search.
///
/// One web view is shared by all windows and moves into whichever window is in
/// front, so the app holds one page in memory, not one per session window.
/// Clicks, menus, questions and keyboard shortcuts stay native: the page calls
/// the app through `window.webkit.messageHandlers.sessions`.
@MainActor
final class SessionsWeb: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate, ObservableObject {
    /// The sidebar page.
    static let shared = SessionsWeb(path: "sidebar")
    /// The banner above the terminal: this session, its login, what it needs, and its tabs.
    static let banner = SessionsWeb(path: "banner")

    let webView: WKWebView
    let path: String
    private var loaded = false
    /// The panel above the terminal has one fixed height, so nothing ever jumps.
    /// banner.html lays itself out for exactly this height.
    static let bannerHeight: CGFloat = 136

    init(path: String) {
        self.path = path
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = SessionsWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(self, name: "sessions")
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "sessionsReply")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        load()
    }

    /// The page from the app bundle. The base URL keeps the address the helper used to
    /// serve it from, so what the page remembers (row order, folded groups, column
    /// settings: its localStorage) carries over.
    private func load() {
        let file = path == "sidebar" ? "switchboard-sidebar" : "switchboard-panel"
        guard let url = Bundle.main.url(forResource: file, withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        webView.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:4477/\(path)"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A new page (first load, or a reload) knows nothing yet.
        pageReady()
    }

    private func pageReady() {
        lastContext = ""
        if let json = Switchboard.shared.currentJSON() { setData(json) }
        if path == "sidebar" { setFocus(SessionsStore.shared.focusedSurfaceID) } else { pushBannerContext() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastContext = ""
        load()
    }

    /// The sessions (the tracker's JSON), whenever they change.
    func setData(_ json: String) {
        let fn = path == "sidebar" ? "Sessions" : "Banner"
        webView.evaluateJavaScript("window.\(fn) && \(fn).setData && \(fn).setData(\(json))")
    }

    // MARK: Banner context (which window, its terminals, its tabs, update)

    private var lastContext = ""

    /// Tell the banner which session window is in front, its terminals and tabs.
    func pushBannerContext() {
        guard path == "banner" else { return }
        // The window that holds the banner now (it follows the front window), even
        // when the app is not active.
        let candidates = [webView.window, NSApp.keyWindow, NSApp.mainWindow]
        let key = candidates.compactMap { $0 }.first { $0.windowController is BaseTerminalController }
        // The panel belongs to the whole window (the session), not to one tab: send
        // the terminals of every tab, first tab first, so a new shell tab keeps the
        // same session above it.
        // One window holds every session: the panel shows the tabs of the session you are in.
        let shown = key.map { $0.tabGroup?.selectedWindow ?? $0 }
        let windows: [NSWindow] = (shown?.windowController as? TerminalController)
            .map { SessionsAPI.windows(ofWorkspace: $0.sessionsWorkspace) } ?? shown.map { [$0] } ?? []
        let surfaces = windows.flatMap {
            ($0.windowController as? BaseTerminalController)?.surfaceTree.root?.leaves().map { $0.id.uuidString } ?? []
        }
        var tabs: [[String: Any]] = []
        if let key {
            // Tabs live in the panel, always shown. TerminalWindow hides the macOS tab bar.
            let selected = shown ?? key
            for w in windows {
                let surfaceTitle = (w.windowController as? BaseTerminalController)?.focusedSurface?.title ?? ""
                let title = !surfaceTitle.isEmpty ? surfaceTitle : (w.title == "Switchboard" || w.title.isEmpty ? "Terminal" : w.title)
                tabs.append(["id": w.windowNumber, "title": title, "selected": w === selected])
            }
        }
        var ctx: [String: Any] = ["surfaces": surfaces, "tabs": tabs]
        let v = SessionsVersion.shared
        if v.updateAvailable { ctx["update"] = ["running": v.runningBuild, "installed": v.installedBuild] }
        guard let data = try? JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        if json == lastContext { return }
        lastContext = json
        webView.evaluateJavaScript("window.Banner ? (Banner.setContext(\(json)), true) : false") { [weak self] result, _ in
            // Not delivered (the page was still loading): send it again next time.
            if (result as? Bool) != true { self?.lastContext = "" }
        }
    }

    /// Links (artifacts and so on) open in the browser, not inside the sidebar.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            SessionsLinkOpener.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: App → page

    func setFolder(_ path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [path]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.Sessions && Sessions.setFolder(\(json)[0])")
    }

    func setFocus(_ id: String?) {
        let arg = id.map { "'\($0)'" } ?? "null"
        webView.evaluateJavaScript("window.Sessions && Sessions.setFocus(\(arg))")
    }

    func focusSearch() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.Sessions && Sessions.focusSearch()")
    }

    // MARK: Page → app

    /// Questions with an answer: search.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any] else { replyHandler(nil, nil); return }
        if body["type"] as? String == "pasteFiles" {
            // A paste in the new-session form with files or a picture in it: their paths.
            replyHandler(["paths": SessionsAttachments.fromPasteboard(.general)], nil)
            return
        }
        guard body["type"] as? String == "search" else { replyHandler(nil, nil); return }
        let q = (body["q"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var reply: [String: Any] = ["s": Switchboard.shared.search(q)]
        // A pasted session id (or "claude --resume <id>"): offer to resume it.
        guard let r = q.lowercased().range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression) else {
            replyHandler(reply, nil)
            return
        }
        let sid = String(q.lowercased()[r])
        Task { @MainActor in
            reply["id"] = await Switchboard.shared.lookupSessionID(sid) ?? ["id": sid, "missing": true]
            replyHandler(reply, nil)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let store = SessionsStore.shared
        switch type {
        case "ready":
            pageReady()
        case "newFolder":
            // The folder new sessions start in: the spares wait there.
            if let cwd = body["cwd"] as? String, !cwd.isEmpty { SBSpares.shared.folder = SBPaths.expand(cwd) }
        case "open":
            guard let k = body["k"] as? String else { return }
            store.open(key: k)
        case "folderMenu":
            // Where new sessions start: your usual folders, or any folder.
            let folders = body["folders"] as? [String] ?? []
            let current = body["current"] as? String ?? ""
            menuActions = []
            let menu = NSMenu()
            let head = NSMenuItem(title: "Start new sessions in:", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for f in folders {
                menu.addItem(item(f, checked: f == current) { [weak self] in self?.setFolder(f) })
            }
            menu.addItem(.separator())
            menu.addItem(item("Other folder…") { [weak self] in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Use this folder"
                panel.message = "New sessions start in this folder."
                panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let home = NSHomeDirectory()
                let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
                self?.setFolder(path)
            })
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            let point = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            menu.popUp(positioning: nil, at: point, in: webView)
        case "nav":
            store.navOrder = body["keys"] as? [String] ?? []
        case "menu":
            guard let k = body["k"] as? String, let s = store.payload?.s.first(where: { $0.k == k }) else { return }
            showMenu(for: s)
        case "loginMenu":
            // A native menu, so it draws over the terminal instead of being cut off by the banner.
            guard let k = body["k"] as? String else { return }
            let current = body["ld"] as? String ?? ""
            menuActions = []
            let menu = NSMenu()
            let head = NSMenuItem(title: "Resume this conversation with:", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for (dir, name) in [("~/.claude", "simplero.com"), ("~/.claude-ccl", "corre.li"), ("~/.claude-ccm", "correli.me")] {
                let i = item(dir == current ? "\(name) (now)" : name, checked: dir == current) {
                    store.send(["op": "switch", "k": k, "login": dir])
                }
                if dir == current { i.action = nil }
                menu.addItem(i)
            }
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            let point = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            menu.popUp(positioning: nil, at: point, in: webView)
        case "openLink":
            guard let u = body["url"] as? String, let url = URL(string: u) else { return }
            SessionsLinkOpener.open(url)
        case "linksMenu":
            // Every link of the session, when the panel has no room for all of them.
            let links = (body["links"] as? [[String]] ?? []).filter { $0.count >= 4 }
            guard !links.isEmpty else { return }
            menuActions = []
            let menu = NSMenu()
            for (kind, head) in [("dev", "Dev pages (Chrome)"), ("doc", "Docs"), ("artifact", "Artifacts")] {
                let group = links.filter { $0[0] == kind }
                if group.isEmpty { continue }
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                let h = NSMenuItem(title: head, action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
                for l in group {
                    let i = item(l[3].isEmpty ? l[2] : "\(l[2])  ·  \(l[3])") {
                        if let url = URL(string: l[1]) { SessionsLinkOpener.open(url) }
                    }
                    i.toolTip = l[1]
                    menu.addItem(i)
                }
            }
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            let point = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            menu.popUp(positioning: nil, at: point, in: webView)
        case "switchLogin":
            guard let k = body["k"] as? String, let login = body["login"] as? String else { return }
            store.send(["op": "switch", "k": k, "login": login])
        case "op":
            if let o = body["o"] as? [String: Any] {
                if let op = o["op"] as? String, let k = o["k"] as? String,
                   let action = ["done": "Done with", "close": "Close", "park": "Park"][op],
                   !store.confirmClose(k, action: action) { return }
                if o["op"] as? String == "new" {
                    // The form cleared itself: give the message back if the session did not start.
                    store.send(o) { [weak self] ok in
                        if !ok { self?.webView.evaluateJavaScript("window.Sessions && Sessions.newFailed && Sessions.newFailed()") }
                    }
                    return
                }
                store.send(o)
            }
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
            // Close this tab only (asks first if something still runs in it).
            if let controller = w.windowController as? TerminalController { controller.closeTab(nil) } else { w.performClose(nil) }
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
        if s.isOpen || !s.isArchived {
            menu.addItem(item(s.a == "shell" ? "Done (close it and its tabs)" : "Done (close it, move it to the Archive)") {
                guard store.confirmClose(s.k, action: "Done with") else { return }
                store.send(["op": "done", "k": s.k])
            })
        }
        if s.isOpen && s.a != "shell" {
            // A shell has nothing to resume, so it cannot be parked or closed "for later".
            menu.addItem(item("Park (close it, keep it here)") {
                guard store.confirmClose(s.k, action: "Park") else { return }
                store.send(["op": "park", "k": s.k])
            })
            menu.addItem(item("Close") {
                guard store.confirmClose(s.k, action: "Close") else { return }
                store.send(["op": "close", "k": s.k])
            })
        } else if s.isParked {
            menu.addItem(item("Unpark") { store.open(s) })
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
                    if let url = URL(string: u) { SessionsLinkOpener.open(url) }
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

/// The pages' web view. Files dropped on it: the page only learns their names, so their paths
/// go to the sidebar page from here (the new-session form attaches them).
final class SessionsWebView: WKWebView {
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let done = super.performDragOperation(sender)
        if !urls.isEmpty, let data = try? JSONSerialization.data(withJSONObject: urls.map(\.path)),
           let json = String(data: data, encoding: .utf8) {
            evaluateJavaScript("window.Sessions && Sessions.droppedFiles && Sessions.droppedFiles(\(json))")
        }
        return done
    }
}

/// Files for a new session's first message.
enum SessionsAttachments {
    /// Pictures you paste are saved here; Claude reads them by their path.
    static var folder: String { SBPaths.data + "/attachments" }

    /// What a paste adds: copied files by their own paths, else a copied picture (a
    /// screenshot) saved as a PNG file.
    @MainActor
    static func fromPasteboard(_ pb: NSPasteboard) -> [String] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map(\.path) }
        var png = pb.data(forType: .png)
        if png == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { return [] }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let path = "\(folder)/pasted-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased()).png"
        return SBFiles.writeAtomic(png, path) ? [path] : []
    }

    /// Pasted pictures older than 30 days go (a session that still needs one has read it by then).
    static func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for n in names where n.hasPrefix("pasted-") {
            let p = folder + "/" + n
            if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, d < cutoff { try? fm.removeItem(atPath: p) }
        }
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


/// Opens web links where Link Router would (dev pages in Chrome, artifacts in the Arc
/// Space of the login that published them, Docs in the main Space), when Link Router is
/// installed, even while it is not the default browser. Otherwise the default browser.
enum SessionsLinkOpener {
    static let routerID = "com.simplero.link-router"

    static func open(_ url: URL) {
        let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        if web, let router = NSWorkspace.shared.urlForApplication(withBundleIdentifier: routerID) {
            NSWorkspace.shared.open([url], withApplicationAt: router, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
            return
        }
        NSWorkspace.shared.open(url)
    }
}
