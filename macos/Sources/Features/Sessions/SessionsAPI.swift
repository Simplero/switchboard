import AppKit
import Foundation
import Network
import GhosttyKit
import CoreImage
import IOSurface
import WebKit
import SwiftUI

/// A small local HTTP API for checks and scripts: list the terminals (with tty and
/// pid), read their text, type into them, focus, close, open tabs, see what the
/// sidebar gets, run a sidebar op, and render a window to PNG without taking the screen.
/// The terminal helpers below are also what the session tracker (Switchboard) uses.
///
/// Listens on 127.0.0.1 only. Every request must carry the token written to
/// ~/.config/session-inbox/ghostty-api.json at launch.
@MainActor
final class SessionsAPI {
    static let shared = SessionsAPI()

    private var listener: NWListener?
    private let token = UUID().uuidString
    private(set) var port: UInt16 = 4478

    private var infoURL: URL {
        // SESSIONS_API_INFO lets a test copy run without taking over the real app's API file.
        if let p = ProcessInfo.processInfo.environment["SESSIONS_API_INFO"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/session-inbox/ghostty-api.json")
    }

    func start() {
        guard listener == nil else { return }
        listen(on: 4478)
    }

    /// Bind 127.0.0.1:<port>; if it is taken (another copy runs), try the next one.
    private func listen(on candidate: UInt16) {
        guard candidate <= 4498 else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
        guard let l = try? NWListener(using: params) else { listen(on: candidate + 1); return }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = candidate
                    self.writeInfo()
                case .failed:
                    l.cancel()
                    if self.listener === l { self.listener = nil }
                    self.listen(on: candidate + 1)
                default:
                    break
                }
            }
        }
        listener = l
        l.start(queue: .main)
    }

    private func writeInfo() {
        let dir = infoURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info: [String: Any] = ["port": Int(port), "token": token, "pid": Int(getpid())]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: infoURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: infoURL.path)
        }
    }

    // MARK: HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Request(buf) {
                    if req.method == "POST", req.path == "/sb/op", req.headers["x-token"] == self.token {
                        // For checks: run an op the way the sidebar does, and answer when it is done.
                        Task { @MainActor in
                            let (ok, message) = await Switchboard.shared.dispatch(req.json)
                            self.respond(conn, status: 200, body: ["ok": ok, "message": message])
                        }
                        return
                    }
                    if req.method == "POST", req.path == "/sb/eval", req.headers["x-token"] == self.token {
                        // For checks: run JavaScript in the sidebar or the panel page and return its result.
                        let page = req.json["page"] as? String == "banner" ? SessionsWeb.banner : SessionsWeb.shared
                        page.webView.callAsyncJavaScript(req.json["js"] as? String ?? "", arguments: [:], in: nil, in: .page) { result in
                            Task { @MainActor in
                                switch result {
                                case .success(let v): self.respond(conn, status: 200, body: ["result": v ?? NSNull()])
                                case .failure(let e): self.respond(conn, status: 500, body: ["error": "\(e)"])
                                }
                            }
                        }
                        return
                    }
                    if req.method == "POST", req.path == "/sb/links", req.headers["x-token"] == self.token {
                        // For checks: the links (and, with "brief": true, the brief) of any conversation id.
                        let sid = req.json["sid"] as? String ?? ""
                        let withBrief = req.json["brief"] as? Bool == true
                        let login = req.json["login"] as? String
                        Task.detached(priority: .userInitiated) {
                            let links = SBLinks.index([(sid: sid, loginDir: login)])[sid] ?? []
                            let rows: [[String: Any]] = links.map { ["kind": $0.kind, "url": $0.url, "title": $0.title ?? NSNull(), "label": SBLinks.label($0), "login": $0.login ?? NSNull()] }
                            var body: [String: Any] = ["links": rows, "chrome": SBLinks.chromeCount]
                            if withBrief, let b = SBLinks.brief(sid) {
                                body["brief"] = ["goal": b.goal, "open": b.open.map { ["who": $0.who ?? "", "text": $0.text] }]
                            }
                            await MainActor.run { self.respond(conn, status: 200, body: body) }
                        }
                        return
                    }
                    if req.method == "GET", req.path == "/sb/snap", req.headers["x-token"] == self.token {
                        // For checks: a picture of the sidebar or the panel page (window pictures leave web views blank).
                        let page = req.query["page"] == "banner" ? SessionsWeb.banner : SessionsWeb.shared
                        page.webView.takeSnapshot(with: nil) { image, _ in
                            Task { @MainActor in
                                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                                      let png = rep.representation(using: .png, properties: [:]) else {
                                    self.respond(conn, status: 500, body: ["error": "no image"]); return
                                }
                                self.respond(conn, status: 200, body: ["png": png.base64EncodedString()])
                            }
                        }
                        return
                    }
                    let (status, body) = self.handle(req)
                    self.respond(conn, status: status, body: body)
                } else if done || error != nil || buf.count > (4 << 20) {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, status: Int, body: Any) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        if status != 200 { head = head.replacingOccurrences(of: " OK", with: " Error") }
        var out = Data(head.utf8)
        out.append(json)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let json: [String: Any]

        init?(_ data: Data) {
            guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            guard let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { return nil }
            method = String(first[0])
            var h: [String: String] = [:]
            for l in lines {
                if let i = l.firstIndex(of: ":") {
                    h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
            }
            headers = h
            let length = Int(h["content-length"] ?? "0") ?? 0
            let bodyStart = sep.upperBound
            guard data.count - bodyStart >= length else { return nil }
            let body = data[bodyStart..<(bodyStart + length)]
            json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let target = String(first[1])
            let comps = URLComponents(string: target)
            path = comps?.path ?? target
            var q: [String: String] = [:]
            for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
            query = q
        }
    }

    private func handle(_ req: Request) -> (Int, Any) {
        guard req.headers["x-token"] == token else { return (403, ["error": "bad token"]) }
        switch (req.method, req.path) {
        case ("GET", "/terminals"):
            return (200, ["terminals": terminals()])
        case ("GET", "/text"):
            guard let view = surface(req.query["id"]) else { return (404, ["error": "no such terminal"]) }
            let all = view.cachedScreenContents.get()
            let n = Int(req.query["lines"] ?? "0") ?? 0
            let text = n > 0 ? all.components(separatedBy: "\n").suffix(n).joined(separator: "\n") : all
            return (200, ["text": text])
        case ("POST", "/input"):
            guard let id = req.json["id"] as? String,
                  SessionsAPI.sendInput(id, text: req.json["text"] as? String ?? "", enter: (req.json["enter"] as? Bool) == true)
            else { return (404, ["error": "no such terminal"]) }
            return (200, ["ok": true])
        case ("POST", "/focus"):
            guard let view = surface(req.json["id"] as? String) else { return (404, ["error": "no such terminal"]) }
            SessionsAPI.focus(view)
            return (200, ["ok": true])
        case ("POST", "/close"):
            guard let id = req.json["id"] as? String, SessionsAPI.closeTerminal(id) else { return (404, ["error": "no such terminal"]) }
            return (200, ["ok": true])
        case ("POST", "/closewindow"):
            guard let id = req.json["id"] as? String, SessionsAPI.closeSession(id) else { return (404, ["error": "no such terminal"]) }
            return (200, ["ok": true])
        case ("POST", "/new"):
            guard let made = SessionsAPI.openTab(
                cwd: req.json["cwd"] as? String, input: req.json["input"] as? String,
                env: req.json["env"] as? [String: String] ?? [:], focus: (req.json["focus"] as? Bool) ?? true,
                split: (req.json["split"] as? Bool) == true, tabOf: req.json["tab_of"] as? String,
                title: req.json["title"] as? String)
            else { return (500, ["error": "no terminal"]) }
            return (200, ["id": made.id, "tab": made.tab, "ws": made.ws])
        case ("GET", "/sb/payload"):
            // For checks: what the sidebar gets now.
            return (200, Switchboard.shared.payloadObject())
        case ("POST", "/newtab"):
            // A real tab in the front session window (what ⌘T does). Used to check the banner tabs.
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let window = NSApp.keyWindow ?? SessionsAPI.mainWindow().map({ $0.tabGroup?.selectedWindow ?? $0 })
            else { return (404, ["error": "no window"]) }
            _ = TerminalController.newTab(appDelegate.ghostty, from: window)
            return (200, ["ok": true])
        case ("POST", "/check"):
            // For checks only: run what a key does (no keystrokes needed). {"id", "do": "closeWindow" | "tab", "n"}
            guard let view = surface(req.json["id"] as? String),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController else {
                return (404, ["error": "no such terminal"])
            }
            switch req.json["do"] as? String {
            case "closeWindow": controller.closeWindow(nil)
            case "tab": SessionsAPI.gotoSessionTab(req.json["n"] as? Int ?? 1, from: controller)
            default: return (400, ["error": "unknown check"])
            }
            return (200, ["ok": true])
        case ("POST", "/sb/restart"):
            // For checks: what "Restart to update" does, without the question.
            Task { @MainActor in SessionsVersion.shared.restart(confirm: false) }
            return (200, ["ok": true])
        case ("GET", "/sb/termshot"):
            // For checks: what a terminal drew (?id=, or ?spare=<login dir>), read from its
            // layer, without a screen capture.
            let view = surface(req.query["id"]) ?? req.query["spare"].flatMap { SBSpares.shared.spares[$0]?.view }
            guard let view else { return (404, ["error": "no such terminal"]) }
            guard let png = SessionsAPI.drawnPicture(view) else { return (200, ["png": NSNull(), "note": "nothing drawn yet"]) }
            return (200, ["png": png.base64EncodedString()])
        case ("POST", "/sb/keycheck"):
            // For checks: press a key with ⌘ on the sidebar page the way AppKit dispatches it
            // (local monitors, the window's views, then the menu). {"key": "v"}
            let web = SessionsWeb.shared.webView
            guard let w = web.window else { return (404, ["error": "no sidebar window"]) }
            w.makeFirstResponder(web)
            let ch = req.json["key"] as? String ?? "v"
            let code: UInt16 = ["v": 9, "c": 8, "x": 7, "a": 0][ch] ?? 9
            guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                            context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                            isARepeat: false, keyCode: code) else { return (500, ["error": "no event"]) }
            let before = String(describing: w.firstResponder.map { type(of: $0) })
            if req.json["direct"] as? Bool == true {
                // What the Paste menu item does once AppKit routes it to the page.
                let ok = NSApp.sendAction(Selector(("paste:")), to: web, from: nil)
                return (200, ["sent": ok])
            }
            if req.json["probe"] as? Bool == true {
                // Which view takes it: ask the terminals and the web views one by one.
                var hits: [String] = []
                var stack: [NSView] = [w.contentView?.superview ?? w.contentView].compactMap { $0 }
                while let v = stack.popLast() {
                    if v is Ghostty.SurfaceView || v is WKWebView {
                        let focused = (v as? Ghostty.SurfaceView)?.focused
                        let name = v === SessionsWeb.shared.webView ? "sidebar page" : v === SessionsWeb.banner.webView ? "panel page" : "\(type(of: v))"
                        hits.append("\(name) focused=\(String(describing: focused)) takes=\(v.performKeyEquivalent(with: ev))")
                    } else { stack += v.subviews }
                }
                return (200, ["views": hits])
            }
            var by = "nothing"
            if w.performKeyEquivalent(with: ev) { by = "window views" } else if NSApp.mainMenu?.performKeyEquivalent(with: ev) == true { by = "menu" }
            return (200, ["handled_by": by, "first_responder_before": before,
                          "first_responder_after": String(describing: w.firstResponder.map { type(of: $0) }),
                          "app_active": NSApp.isActive, "window_is_key": w.isKeyWindow])
        case ("GET", "/sb/phonelink"):
            // For checks: the Phone Link window's content as a picture (not shown on screen), and
            // the account state. ?report=1 reports this Mac to Simplero first.
            let a = SBAccount.shared
            let renderer = ImageRenderer(content: PhoneLinkView(account: a).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let png = renderer.nsImage.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0) }
                .flatMap { $0.representation(using: .png, properties: [:]) }
            return (200, ["signed_in": a.signedIn, "person": a.person?.name ?? NSNull(), "machine_id": SBAccount.machineID,
                          "machines": a.machines.map { ["id": $0.id, "name": $0.name, "online": $0.online, "address": $0.address] },
                          "last_report": a.lastReport.map { $0.timeIntervalSince1970 } ?? NSNull(),
                          "problem": a.problem ?? NSNull(), "png": png?.base64EncodedString() ?? NSNull()])
        case ("POST", "/sb/phonelink/report"):
            Task { @MainActor in await SBAccount.shared.report() }
            return (200, ["ok": true])
        case ("POST", "/sb/docpane"):
            // For checks: open a page next to the session of a terminal (?id), as a Doc link does.
            guard let view = surface(req.json["id"] as? String),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController,
                  let url = URL(string: req.json["url"] as? String ?? "") else { return (404, ["error": "no such terminal"]) }
            if req.json["close"] as? Bool == true { SessionsDocPanes.shared.close(session: controller.sessionsWorkspace) }
            else { SessionsDocPanes.shared.open(url, session: controller.sessionsWorkspace) }
            return (200, ["session": controller.sessionsWorkspace])
        case ("GET", "/sb/docpane"):
            // For checks: the page next to a terminal's session, its size, and the terminal's grid.
            guard let view = surface(req.query["id"]),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController else { return (404, ["error": "no such terminal"]) }
            let page = SessionsDocPanes.shared.pages[controller.sessionsWorkspace]
            return (200, ["open": page != nil, "title": page?.title ?? "", "url": page?.webView.url?.absoluteString ?? "",
                          "in_window": page?.webView.window === controller.window,
                          "pane_width": page?.webView.frame.width ?? 0,
                          "grid": SessionsAPI.gridSize(view).map { [$0.cols, $0.rows] } ?? []])
        case ("GET", "/sb/spares"):
            // For checks: the spares (Claude started ahead of time, one per login).
            return (200, ["spares": SBSpares.shared.checkInfo()])
        case ("POST", "/sb/pastecheck"):
            // For checks: what a paste in the new-session form attaches, from a private
            // pasteboard (never the clipboard you use). {"png": base64} or {"paths": [...]}
            let pb = NSPasteboard(name: NSPasteboard.Name("switchboard-check"))
            pb.clearContents()
            if let paths = req.json["paths"] as? [String] { pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL }) }
            if let b64 = req.json["png"] as? String, let data = Data(base64Encoded: b64) { pb.setData(data, forType: .png) }
            return (200, ["has_files": SessionsAttachments.hasFiles(pb), "paths": SessionsAttachments.fromPasteboard(pb)])
        case ("POST", "/merge"):
            return (200, ["moved": SessionsAPI.mergeAll()])
        case ("GET", "/screenshot"):
            // For checking the sidebar without taking the user's screen: renders a window to PNG.
            // The tab in front of the one window (background tabs also count as "visible"),
            // or the window of a given terminal (?id=).
            let windows = SessionsAPI.allControllers().compactMap { $0.window }.filter { $0.isVisible }
            let chosen = surface(req.query["id"]).flatMap { BaseTerminalController.controller(owning: $0)?.window }
            guard let window = chosen ?? windows.first(where: { $0.isKeyWindow })
                    ?? SessionsAPI.mainWindow().map({ $0.tabGroup?.selectedWindow ?? $0 }) ?? windows.first,
                  let view = window.contentView?.superview ?? window.contentView else { return (404, ["error": "no window"]) }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return (500, ["error": "no image"]) }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return (500, ["error": "no png"]) }
            return (200, ["png": png.base64EncodedString(), "width": view.bounds.width, "height": view.bounds.height])
        default:
            return (404, ["error": "unknown endpoint"])
        }
    }

    // MARK: Terminals

    /// The app's terminal windows, without spares (SBSpares): those are not sessions yet.
    static func allControllers() -> [BaseTerminalController] {
        NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
            .filter { ($0 as? TerminalController)?.sessionsSpare != true }
    }

    static func allSurfaces() -> [Ghostty.SurfaceView] {
        allControllers().flatMap { $0.surfaceTree.root?.leaves() ?? [] }
    }

    private func surface(_ id: String?) -> Ghostty.SurfaceView? { SessionsAPI.surface(id: id) }

    // MARK: One window, every session a set of tabs in it

    /// The tab of each session you used last (session id → window number).
    static var lastActive: [String: Int] = [:]

    static func trackActiveTabs() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      let controller = window.windowController as? TerminalController else { return }
                lastActive[controller.sessionsWorkspace] = window.windowNumber
                // A second window (Dock "New Window", a file dropped on the Dock icon, …)
                // joins the one window as its own session.
                if let main = mainWindow(), let group = main.tabGroup, window.tabGroup !== group {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated { _ = mergeAll() }
                    }
                }
            }
        }
    }

    /// ⌘1…⌘9: tab n of this session (⌘9: its last tab).
    static func gotoSessionTab(_ n: Int, from controller: TerminalController) {
        let tabs = controller.sessionTabWindows
        guard let target = n == 9 ? tabs.last : (n >= 1 && n <= tabs.count ? tabs[n - 1] : nil),
              target !== controller.window else { return }
        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    /// Run a close without registering Undo (the terminals end now).
    static func withoutUndo(_ controller: BaseTerminalController, _ body: () -> Void) {
        var managers: [UndoManager] = []
        for c in [controller] + allControllers() {
            if let u = c.undoManager, !managers.contains(where: { $0 === u }) { managers.append(u) }
        }
        managers.forEach { $0.disableUndoRegistration() }
        body()
        managers.forEach { $0.enableUndoRegistration() }
    }

    /// The tabs of one session, in tab order.
    static func windows(ofWorkspace id: String) -> [NSWindow] {
        let all = allControllers().compactMap { $0 as? TerminalController }.filter { $0.sessionsWorkspace == id }.compactMap { $0.window }
        guard let order = all.first?.tabGroup?.windows else { return all }
        return order.filter { w in all.contains { $0 === w } } + all.filter { w in !order.contains { $0 === w } }
    }

    /// The Switchboard window: the tab group that holds the sessions (the biggest one,
    /// if something opened a second window).
    static func mainWindow() -> NSWindow? {
        let all = allControllers().filter { $0 is TerminalController }.compactMap { $0.window }
        // Visible windows first; while the app starts hidden (a restart in the background),
        // any terminal window, so new sessions still join one window.
        let shown = all.filter { $0.isVisible || $0.isMiniaturized }
        return (shown.isEmpty ? all : shown).max { ($0.tabGroup?.windows.count ?? 1) < ($1.tabGroup?.windows.count ?? 1) }
    }

    /// Show a session: the tab of it you used last (a shell tab, say), else its own terminal.
    static func focus(_ view: Ghostty.SurfaceView) {
        guard let controller = BaseTerminalController.controller(owning: view) else { return }
        if let tc = controller as? TerminalController, let n = lastActive[tc.sessionsWorkspace],
           let last = NSApp.window(withWindowNumber: n), last !== controller.window,
           (last.windowController as? TerminalController)?.sessionsWorkspace == tc.sessionsWorkspace {
            last.tabGroup?.selectedWindow = last
            last.makeKeyAndOrderFront(nil)
            return
        }
        if let window = controller.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        controller.focusSurface(view)
    }

    /// Put every terminal window into the main window, each as its own session (a
    /// window from before the one-window model, or one something else opened).
    static func mergeAll() -> Int {
        guard let main = mainWindow(), let mainGroup = main.tabGroup else { return 0 }
        var moved = 0
        for controller in allControllers().compactMap({ $0 as? TerminalController }) {
            guard let window = controller.window, window.isVisible, window.tabGroup !== mainGroup else { continue }
            for w in window.tabGroup?.windows ?? [window] {
                guard let last = mainGroup.windows.last, last.addTabbedWindowSafely(w, ordered: .above) else { continue }
                moved += 1
            }
        }
        return moved
    }

    private func terminals() -> [[String: Any]] {
        SessionsAPI.terminalList().map { t in
            ["id": t.id, "tab": t.tab, "ws": t.ws, "tab_title": t.tabTitle, "title": t.title,
             "program_title": t.programTitle, "tty": t.tty, "pid": t.pid, "cwd": t.cwd,
             "focused": t.focused, "selected": t.selected, "surfaces_in_tab": t.surfacesInTab,
             "first_responder": surface(t.id).map { $0.window?.firstResponder === $0 } ?? false,
             "grid": surface(t.id).flatMap(SessionsAPI.gridSize).map { [$0.cols, $0.rows] } ?? []]
        }
    }

    /// One terminal of the app, as the session tracker sees it.
    struct Terminal {
        let id: String
        /// The tab (window) it is in. Stable while the tab lives.
        let tab: String
        /// The session it belongs to (its tabs share this id).
        let ws: String
        let tabTitle: String
        let title: String
        /// What the program in the terminal set (Claude's own title), even under a fixed title.
        let programTitle: String
        let tty: String
        let pid: Int
        let cwd: String
        let focused: Bool
        let selected: Bool
        let surfacesInTab: Int
    }

    static func terminalList() -> [Terminal] {
        let key = NSApp.keyWindow
        var out: [Terminal] = []
        for controller in allControllers() {
            let tab = ScriptTab.stableID(controller: controller)
            let ws = (controller as? TerminalController)?.sessionsWorkspace ?? ""
            let tabTitle = controller.window?.title ?? ""
            let leaves = controller.surfaceTree.root?.leaves() ?? []
            for view in leaves {
                out.append(Terminal(
                    id: view.id.uuidString, tab: tab, ws: ws, tabTitle: tabTitle,
                    title: view.titleOverride ?? view.title, programTitle: view.title,
                    tty: view.surfaceModel?.ttyName ?? "", pid: view.surfaceModel?.foregroundPID ?? 0,
                    cwd: view.pwd ?? "",
                    focused: controller.window === key && controller.focusedSurface === view,
                    selected: controller.window.map { $0.tabGroup?.selectedWindow ?? $0 } === controller.window,
                    surfacesInTab: leaves.count))
            }
        }
        return out
    }

    static func surface(id: String?) -> Ghostty.SurfaceView? {
        guard let id else { return nil }
        return allSurfaces().first(where: { $0.id.uuidString == id })
    }

    /// The screen text of a terminal (with scrollback), the last `lines` lines.
    static func screenText(_ id: String, lines: Int = 120) -> String? {
        guard let view = surface(id: id) else { return nil }
        let all = view.cachedScreenContents.get()
        return lines > 0 ? all.components(separatedBy: "\n").suffix(lines).joined(separator: "\n") : all
    }

    /// The active area of a terminal (its last screenful, whatever is scrolled into view).
    /// Cheap: it does not copy the scrollback.
    static func activeText(_ id: String) -> String? {
        surface(id: id).flatMap(activeText(of:))
    }

    static func activeText(of view: Ghostty.SurfaceView) -> String? {
        guard let s = view.surface else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &text) else { return nil }
        defer { ghostty_surface_free_text(s, &text) }
        return String(cString: text.text)
    }

    /// Type text into a terminal, then Enter if asked.
    static func sendInput(_ id: String, text: String, enter: Bool) -> Bool {
        guard let view = surface(id: id), let model = view.surfaceModel else { return false }
        if !text.isEmpty { model.sendText(text) }
        if enter {
            let delay = text.isEmpty ? 0 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                model.sendKeyEvent(Ghostty.Input.KeyEvent(synthesizing: .enter, action: .press, mods: [], translationMods: []))
                model.sendKeyEvent(Ghostty.Input.KeyEvent(synthesizing: .enter, action: .release, mods: [], translationMods: []))
            }
        }
        return true
    }

    /// Put the keyboard in this terminal. Again a moment later if the sidebar page took it
    /// (the page moves into the window that just came to the front, after a click in it).
    static func focusTerminal(_ id: String) {
        guard let view = surface(id: id) else { return }
        focus(view)
        view.window?.makeFirstResponder(view)
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let v = surface(id: id), let w = v.window, w.firstResponder !== v,
                          (w.tabGroup?.selectedWindow ?? w) === w else { return }
                    // Only from the sidebar page (or nothing): never from a field you clicked meanwhile.
                    let r = w.firstResponder
                    let page = SessionsWeb.shared.webView
                    guard r == nil || r === w || (r as? NSView).map({ $0 === page || $0.isDescendant(of: page) }) == true else { return }
                    w.makeFirstResponder(v)
                }
            }
        }
    }

    /// A spare (SBSpares, Claude already at its prompt) becomes a new session: the last
    /// tab of the one window, in front. Like `openTab`, without the wait for Claude.
    static func adoptSpare(_ controller: TerminalController) -> (id: String, tab: String, ws: String)? {
        guard let window = controller.window, let view = controller.surfaceTree.root?.leaves().first,
              let host = mainWindow() else { return nil }
        let last = host.tabGroup?.windows.last ?? host
        guard last.addTabbedWindowSafely(window, ordered: .above) else { return nil }
        controller.sessionsWorkspace = UUID().uuidString
        last.tabGroup?.selectedWindow = window
        controller.showWindowSafely(nil)
        controller.focusSurface(view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.relabelTabs() }
        return (view.id.uuidString, ScriptTab.stableID(controller: controller), controller.sessionsWorkspace)
    }

    /// What a terminal last drew, as PNG: the renderer puts each frame in an IOSurface as
    /// its layer's contents.
    static func drawnPicture(_ view: Ghostty.SurfaceView) -> Data? {
        var stack = [view.layer].compactMap { $0 }
        while let l = stack.popLast() {
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                let ci = CIImage(ioSurface: c as! IOSurfaceRef)
                guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            stack += l.sublayers ?? []
        }
        return nil
    }

    /// Columns and rows of a terminal.
    static func gridSize(_ view: Ghostty.SurfaceView) -> (cols: Int, rows: Int)? {
        guard let s = view.surface else { return nil }
        let size = ghostty_surface_size(s)
        return (Int(size.columns), Int(size.rows))
    }

    /// Close one terminal, without asking and without Undo (the process ends now
    /// instead of living on for the Undo timeout).
    static func closeTerminal(_ id: String) -> Bool {
        guard let view = surface(id: id), let controller = BaseTerminalController.controller(owning: view) else { return false }
        withoutUndo(controller) { controller.closeSurface(view, withConfirmation: false) }
        return true
    }

    /// Close every tab of the session this terminal belongs to, without asking.
    /// The other sessions in the window stay.
    static func closeSession(_ id: String) -> Bool {
        guard let view = surface(id: id),
              let controller = BaseTerminalController.controller(owning: view) as? TerminalController else { return false }
        withoutUndo(controller) {
            for window in windows(ofWorkspace: controller.sessionsWorkspace) {
                (window.windowController as? TerminalController)?.closeTabImmediately(registerRedo: false)
            }
        }
        return true
    }

    /// Open a terminal: a new session (a new tab at the end of the one window), or with
    /// `tabOf` (a terminal id) a new tab of that terminal's session.
    /// A terminal whose program already runs: its pty handed over by the app that ran
    /// before an update.
    struct AdoptPTY {
        let fd: Int32
        let pid: Int32
        let replay: Data?

        var config: Ghostty.SurfaceConfiguration {
            var c = Ghostty.SurfaceConfiguration()
            c.ptyFD = fd
            c.ptyPID = pid
            c.ptyReplay = replay
            return c
        }
    }

    static func openTab(cwd: String?, input: String?, env: [String: String], focus: Bool,
                        split: Bool = false, tabOf: String? = nil, title: String? = nil,
                        adopt: AdoptPTY? = nil, ws: String? = nil) -> (id: String, tab: String, ws: String)? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return nil }
        var config = adopt?.config ?? Ghostty.SurfaceConfiguration()
        if let cwd, !cwd.isEmpty { config.workingDirectory = cwd }
        if let input, !input.isEmpty { config.initialInput = input }
        config.environmentVariables = env
        // One window holds every session, like cmux: a new session is a new tab at the
        // end of it (the macOS tab bar is hidden; the sidebar and the panel show them).
        let parent = surface(id: tabOf).flatMap { BaseTerminalController.controller(owning: $0)?.window }
        let host = parent ?? mainWindow()
        let controller: TerminalController
        if let host, let tab = TerminalController.newTab(appDelegate.ghostty, from: parent ?? host.tabGroup?.windows.last ?? host,
                                                          withBaseConfig: config, select: focus) {
            controller = tab
        } else {
            controller = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config)
        }
        // newTab gave it the session of its parent; a new session gets its own id
        // (or keeps the one it had, after an update).
        if let ws, !ws.isEmpty { controller.sessionsWorkspace = ws } else if parent == nil { controller.sessionsWorkspace = UUID().uuidString }
        guard let view = controller.surfaceTree.root?.leaves().first else { return nil }
        if let title, !title.isEmpty { view.titleOverride = title }
        if split {
            var shell = Ghostty.SurfaceConfiguration()
            shell.workingDirectory = config.workingDirectory
            _ = controller.newSplit(at: view, direction: .right, baseConfig: shell)
            controller.focusSurface(view)
        }
        return (view.id.uuidString, ScriptTab.stableID(controller: controller), controller.sessionsWorkspace)
    }

    /// A split next to a terminal, taking over a handed-over pty.
    static func adoptSplit(nextTo id: String, adopt: AdoptPTY) -> String? {
        guard let view = surface(id: id), let controller = BaseTerminalController.controller(owning: view),
              let made = controller.newSplit(at: view, direction: .right, baseConfig: adopt.config) else { return nil }
        return made.id.uuidString
    }
}

