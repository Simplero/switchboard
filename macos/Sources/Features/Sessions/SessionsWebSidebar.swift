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
    static let bannerHeight: CGFloat = 158

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
        if path == "sidebar" {
            setFocus(SessionsStore.shared.focusedSurfaceID)
            setHistory(back: SessionHistory.shared.canGoBack, forward: SessionHistory.shared.canGoForward)
        } else { pushBannerContext() }
    }

    /// Whether the ‹ and › buttons can go anywhere.
    func setHistory(back: Bool, forward: Bool) {
        guard path == "sidebar" else { return }
        webView.evaluateJavaScript("window.Sessions && Sessions.setHistory && Sessions.setHistory(\(back), \(forward))")
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

    func setColFolder(_ col: Int, _ path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [path]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.Sessions && Sessions.setColFolder(\(col), \(json)[0])")
    }

    func setFolder(_ path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [path]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.Sessions && Sessions.setFolder(\(json)[0])")
    }

    func setFocus(_ id: String?) {
        let arg = id.map { "'\($0)'" } ?? "null"
        webView.evaluateJavaScript("window.Sessions && Sessions.setFocus(\(arg))")
    }

    func focusSearch(tries: Int = 10) {
        // Just shown (⌘P with the sidebar hidden): the page joins the window a moment later.
        guard let w = webView.window, w.isKeyWindow || tries == 0 else {
            if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusSearch(tries: tries - 1) } }
            return
        }
        w.makeFirstResponder(webView)
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
        if body["deep"] as? Bool == true {
            // "Search inside conversations": only when you ask for it.
            Task { @MainActor in replyHandler(await Switchboard.shared.searchConversations(q), nil) }
            return
        }
        // As you type: the sessions in the list, by name, summary, folder…
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
        case "histBack":
            SessionHistory.shared.goBack("the ‹ button")
        case "histForward":
            SessionHistory.shared.goForward("the › button")
        case "movedAway":
            SessionsWebView.listMovedWhileAway = true
        case "histMenu":
            menuActions = []
            let menu = SessionHistory.shared.menu { [unowned self] title, checked, action in self.item(title, checked: checked, action) }
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            let point = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            menu.popUp(positioning: nil, at: point, in: webView)
        case "newWarm":
            // The new-session form opened on a login (or closed): start its Claude now, so it
            // is at its prompt by the time you press Enter.
            // On another machine there is no spare: look whether that machine answers instead.
            let machine = (body["machine"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            SBSpares.shared.want(machine == nil ? body["login"] as? String : nil)
            SessionsWebView.newFormOpen = (body["login"] as? String) != nil
            if let m = SBMachines.named(machine) {
                Task { @MainActor in _ = await SBMachines.prepare(m, force: true); Switchboard.shared.publish() }
            }
        case "newFolder":
            // The folder new sessions start in: the spares wait there.
            if let cwd = body["cwd"] as? String, !cwd.isEmpty { SBSpares.shared.folder = SBPaths.expand(cwd); SBSpares.shared.tick() }
        case "open":
            guard let k = body["k"] as? String else { return }
            store.open(key: k, via: body["via"] as? String ?? "a click on the sidebar")
        case "colFolderMenu":
            // A column shows the sessions of one folder, or of all folders.
            let col = body["col"] as? Int ?? 0
            let folders = (body["folders"] as? [[Any]] ?? []).compactMap { f -> (String, Int)? in
                guard f.count == 2, let p = f[0] as? String else { return nil }
                return (p, (f[1] as? Int) ?? 0)
            }
            let current = body["current"] as? String ?? ""
            menuActions = []
            let menu = NSMenu()
            let head = NSMenuItem(title: "Show the sessions in:", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            menu.addItem(item("All folders", checked: current.isEmpty) { [weak self] in self?.setColFolder(col, "") })
            menu.addItem(.separator())
            if !current.isEmpty && !folders.contains(where: { $0.0 == current }) {
                menu.addItem(item("\(current)  (0)", checked: true) {})
            }
            for (f, n) in folders {
                menu.addItem(item("\(f)  (\(n))", checked: f == current) { [weak self] in self?.setColFolder(col, f) })
            }
            let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
            let point = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            menu.popUp(positioning: nil, at: point, in: webView)
        case "folderMenu":
            // Where new sessions start: your usual folders, or any folder.
            let folders = body["folders"] as? [String] ?? []
            let current = body["current"] as? String ?? ""
            let machine = (body["machine"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            menuActions = []
            let menu = NSMenu()
            let head = NSMenuItem(title: machine.map { "Start it in this folder on \($0):" } ?? "Start new sessions in:", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for f in folders {
                menu.addItem(item(f, checked: f == current) { [weak self] in self?.setFolder(f) })
            }
            menu.addItem(.separator())
            if let machine {
                // A folder there: this Mac cannot browse it, so you type it.
                menu.addItem(item("Other folder on \(machine)…") { [weak self] in
                    self?.ask("Folder on \(machine)", placeholder: "~/Simplero-2", initial: current) { self?.setFolder($0) }
                })
                let x = body["x"] as? Double ?? 0, y = body["y"] as? Double ?? 0
                let point = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
                menu.popUp(positioning: nil, at: point, in: webView)
                return
            }
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
                SessionSwitchLog.because("the sidebar: \(o["op"] as? String ?? "an action")")
                if let op = o["op"] as? String, let k = o["k"] as? String,
                   let action = ["done": "Archive", "close": "Close", "park": "Park"][op],
                   !store.confirmClose(k, action: action) { return }
                if o["op"] as? String == "resume_conv", let key = o["key"] as? String,
                   let d = SBHistory.shared.doc(key), let warning = SBHistory.shared.otherMacWarning(d) {
                    // Another Mac changed it in the last minutes: it may still run there.
                    let alert = NSAlert()
                    alert.messageText = "Resume “\(d.title)” here?"
                    alert.informativeText = warning
                    alert.addButton(withTitle: "Resume here")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    var forced = o
                    forced["force"] = true
                    store.send(forced)
                    return
                }
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
            SessionSwitchLog.because("a tab in the panel")
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

    /// Move to folder: Claude resumes the conversation in the folder you pick, when its turn is
    /// over and you are not looking at it (right away when it waits for you).
    private func moveItems(_ s: SessionItem) -> [NSMenuItem] {
        let store = SessionsStore.shared
        var items: [NSMenuItem] = []
        func disabled(_ t: String) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        }
        if let to = s.mv, s.mvm != true {
            items.append(disabled(s.mvr == "#slot" ? "Puts its work in a slot when its turn is over" : "Moves to \(to) when its turn is over"))
            items.append(item(s.mvr == "#slot" ? "Do it now (stops what it does)" : "Move now (stops what it does)") { store.send(["op": "move", "k": s.k, "cwd": s.mvr ?? to, "now": true]) })
            items.append(item("Don’t move it") { store.send(["op": "move_cancel", "k": s.k]) })
            items.append(.separator())
        }
        let here = s.cwd ?? ""
        if here == Switchboard.defaultFolder && s.isOpen && s.mvr != "#slot" {
            // In the shared checkout: its Claude moves its own changes to a slot of its own.
            items.append(item("Put its work in a slot (out of ~/Simplero)") { store.send(["op": "move", "k": s.k, "cwd": "#slot"]) })
            items.append(.separator())
        }
        for f in Switchboard.shared.usualFolders() {
            if f == here {
                items.append(item("\(f)  (now)", checked: true) {})
                items.last?.action = nil
            } else {
                items.append(item(f, checked: f == s.mv) { store.send(["op": "move", "k": s.k, "cwd": f]) })
            }
        }
        items.append(.separator())
        items.append(item("Other folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Move here"
            panel.message = "Claude resumes “\(s.n)” in this folder."
            panel.directoryURL = URL(fileURLWithPath: (here as NSString).expandingTildeInPath)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            store.send(["op": "move", "k": s.k, "cwd": SBPaths.tilde(url.path)])
        })
        return items
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
        menu.addItem(item(s.isOpen ? "Go to session" : s.isPinned ? "Start it" : "Reopen here") { store.open(s) })
        // A pin stays: no Archive or Close. Unpin it first.
        if s.isPinned {
            let n = (store.pins.firstIndex { $0.k == s.k } ?? 99) + 1
            menu.addItem(item("Unpin" + (n <= 9 ? "  (⌃\(n))" : "")) { store.send(["op": "unpin", "k": s.k]) })
        } else if s.isOpen || s.a != "shell" {
            let n = store.pins.count + 1
            menu.addItem(item("Pin" + (n <= 9 ? "  (⌃\(n) opens it)" : "")) { store.send(["op": "pin", "k": s.k]) })
        }
        // Close: it stops, and stays under Not running until you archive it (a click resumes it).
        // Archive: you are done with it.
        if s.isOpen && !s.isPinned {
            if s.a == "shell" {
                // A shell has nothing to resume, so it is only closed.
                menu.addItem(item("Close (it and its tabs)") {
                    guard store.confirmClose(s.k, action: "Close") else { return }
                    store.send(["op": "done", "k": s.k])
                })
            } else {
                menu.addItem(item("Close (keep it under Not running)") {
                    guard store.confirmClose(s.k, action: "Close") else { return }
                    store.send(["op": "close", "k": s.k])
                })
                menu.addItem(item("Archive (done with it)") {
                    guard store.confirmClose(s.k, action: "Archive") else { return }
                    store.send(["op": "done", "k": s.k])
                })
            }
        } else if !s.isPinned && !s.isOpen && s.a != "shell" {
            if s.isArchived {
                menu.addItem(item("Take it out of the Archive") { store.send(["op": "unarchive", "k": s.k]) })
            } else {
                menu.addItem(item("Move to the Archive") { store.send(["op": "done", "k": s.k]) })
            }
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
        if s.a == "claude" && s.k.hasPrefix("claude:") && s.m == nil {
            menu.addItem(submenu("Move to folder", moveItems(s)))
            let machines = SBMachines.all
            if !machines.isEmpty {
                // With its work tree: the branch, its commits, its uncommitted changes and new files.
                var items: [NSMenuItem] = []
                if s.mvm == true, let to = s.mv {
                    let head = NSMenuItem(title: "Moves to \(to) when its turn is over", action: nil, keyEquivalent: "")
                    head.isEnabled = false
                    items.append(head)
                    items.append(item("Move now (stops what it does)") { store.send(["op": "move", "k": s.k, "cwd": s.mvr ?? "@" + to, "now": true]) })
                    items.append(item("Don’t move it") { store.send(["op": "move_cancel", "k": s.k]) })
                    items.append(.separator())
                }
                for m in machines {
                    items.append(item("\(m.name) (with its work tree)", checked: s.mvm == true && s.mv == m.name) {
                        store.send(["op": "move", "k": s.k, "cwd": "@" + m.name])
                    })
                }
                menu.addItem(submenu("Move to machine", items))
            }
        }
        if !s.isOpen && !s.isPinned {
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
    /// The new-session form is open (the page says so with `newWarm`).
    static var newFormOpen = false

    /// This page (or a view inside it) has the keyboard.
    var hasKeyboard: Bool {
        guard let r = window?.firstResponder as? NSView else { return false }
        return r === self || r.isDescendant(of: self)
    }

    /// ⌘V, ⌘C, ⌘X, ⌘A go straight to the page when it has the keyboard. Through the
    /// menu, ⌘V did not reach the new-session form. A paste with files or a picture on the
    /// clipboard attaches them to the open form (by their paths; a picture is saved as a file).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘ with an arrow (and ⇧ to select) in the open new-session form: it moves in the text,
        // not to another session or tab.
        if Self.newFormOpen, event.type == .keyDown, hasKeyboard,
           event.modifierFlags.contains(.command), (123...126).contains(event.keyCode) {
            keyDown(with: event)
            return true
        }
        guard event.type == .keyDown, hasKeyboard,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            if Self.newFormOpen, SessionsAttachments.hasFiles(.general) {
                let paths = SessionsAttachments.fromPasteboard(.general)
                if let data = try? JSONSerialization.data(withJSONObject: paths), let json = String(data: data, encoding: .utf8) {
                    evaluateJavaScript("window.Sessions && Sessions.droppedFiles && Sessions.droppedFiles(\(json))")
                }
                return true
            }
            action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: self, from: nil)
    }

    /// The page must not look like it has the keyboard when it does not: tell it when the
    /// keyboard leaves (a click in the terminal), and after it moves to another window
    /// (⌘↑ ⌘↓), where the terminal has the keyboard. Its focused field stays focused in the
    /// page otherwise, with a blinking caret.
    /// The rows moved while you were in another app (the page says so, see `Sessions.away`).
    static var listMovedWhileAway = false

    /// The first click on a window in the background also clicks the row (WebKit refuses it
    /// by default, so a click from another app only brought the window forward). Not when that
    /// click brings Switchboard back and the rows moved while you were away: another session
    /// may be where the one you saw was. That click only brings Switchboard forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        let comingBack = !NSApp.isActive || Date().timeIntervalSince(SessionSwitchLog.activeSince) < 0.5
        guard comingBack, Self.listMovedWhileAway else { return true }
        SessionSwitchLog.line("A click on the sidebar brought Switchboard back and opened nothing: the rows moved while you were away")
        return false
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { keyboardLeft() }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let w = self.window else { return }
            let r = w.firstResponder
            if !(r === self || (r as? NSView)?.isDescendant(of: self) == true) { self.keyboardLeft() }
        }
    }

    private func keyboardLeft() {
        evaluateJavaScript("window.Sessions && Sessions.keyboardLeft && Sessions.keyboardLeft()")
    }

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

    /// The clipboard holds files or a picture (not only text).
    static func hasFiles(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }

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


/// `$BROWSER` for everything that runs in Switchboard's terminals. Claude Code opens a link
/// you click in it with "$BROWSER <url>" (else `open`), and so do gh and other tools. The
/// script hands the link to Switchboard with its terminal, so a Simplero Doc opens next to the
/// session it came from and a dev page (.test, .internal) in Chrome; without Switchboard, the
/// link opens as usual.
enum SessionsLinkHelper {
    static var path: String { SBPaths.data + "/bin/switchboard-open" }

    static let script = #"""
    #!/bin/sh
    # Switchboard: BROWSER for the programs in its terminals (written by the app at each start).
    # Hands each link to Switchboard with this terminal; without Switchboard, opens it as usual.
    info="${SESSIONS_API_INFO:-$HOME/.config/session-inbox/ghostty-api.json}"
    tty=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
    for url in "$@"; do
      port=$(sed -n 's/.*"port"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$info" 2>/dev/null)
      token=$(sed -n 's/.*"token"[^"]*"\([^"]*\)".*/\1/p' "$info" 2>/dev/null)
      esc=$(printf '%s' "$url" | sed 's/\\/\\\\/g; s/"/\\"/g')
      if [ -n "$port" ] && curl -sf -m 3 -o /dev/null -H "x-token: $token" -H "Content-Type: application/json" \
           -d "{\"url\":\"$esc\",\"tty\":\"$tty\"}" "http://127.0.0.1:$port/sb/openlink"; then
        continue
      fi
      open "$url"
    done
    """#

    /// Write the script and point BROWSER at it; terminals and their programs inherit it.
    static func install() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard SBFiles.writeAtomic(Data(script.utf8), path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        setenv("BROWSER", path, 1)
    }
}

/// Opens web links where Link Router would (dev pages in Chrome, artifacts in the Arc
/// Space of the login that published them, Docs in the main Space), when Link Router is
/// installed, even while it is not the default browser. Otherwise the default browser.
enum SessionsLinkOpener {
    static let routerID = "com.simplero.link-router"

    /// A Simplero Doc opens next to the session in front (SessionsDocPanes); `nextToSession:
    /// false` (the pane's "Open in your browser") sends it to the browser.
    static func open(_ url: URL, nextToSession: Bool = true) {
        if nextToSession, SessionsDocPanes.isDoc(url), Thread.isMainThread {
            let shown: Bool = MainActor.assumeIsolated {
                guard let ws = SessionsDocPanes.frontSession else { return false }
                SessionsDocPanes.shared.open(url, session: ws)
                return true
            }
            if shown { return }
        }
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
