import AppKit
import Foundation
import Network

/// A small local HTTP API so the session helper (~/code/session-inbox/server.py)
/// can see and drive this app's terminals: list them (with tty and pid), read
/// their text, type into them, focus, close, and open new tabs.
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
            guard let view = surface(req.json["id"] as? String), let model = view.surfaceModel else {
                return (404, ["error": "no such terminal"])
            }
            if let text = req.json["text"] as? String, !text.isEmpty { model.sendText(text) }
            if (req.json["enter"] as? Bool) == true {
                let delay = (req.json["text"] as? String)?.isEmpty == false ? 0.25 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    model.sendKeyEvent(Ghostty.Input.KeyEvent(synthesizing: .enter, action: .press, mods: [], translationMods: []))
                    model.sendKeyEvent(Ghostty.Input.KeyEvent(synthesizing: .enter, action: .release, mods: [], translationMods: []))
                }
            }
            return (200, ["ok": true])
        case ("POST", "/focus"):
            guard let view = surface(req.json["id"] as? String) else { return (404, ["error": "no such terminal"]) }
            SessionsAPI.focus(view)
            return (200, ["ok": true])
        case ("POST", "/close"):
            guard let view = surface(req.json["id"] as? String),
                  let controller = BaseTerminalController.controller(owning: view) else {
                return (404, ["error": "no such terminal"])
            }
            controller.closeSurface(view, withConfirmation: false)
            return (200, ["ok": true])
        case ("POST", "/closewindow"):
            // Done with a session: close every tab of that session, without asking.
            // The other sessions in the window stay.
            guard let view = surface(req.json["id"] as? String),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController else {
                return (404, ["error": "no such terminal"])
            }
            for window in SessionsAPI.windows(ofWorkspace: controller.sessionsWorkspace) {
                (window.windowController as? TerminalController)?.closeTabImmediately(registerRedo: false)
            }
            return (200, ["ok": true])
        case ("POST", "/new"):
            return newTab(req.json)
        case ("POST", "/newtab"):
            // A real tab in the front session window (what ⌘T does). Used to check the banner tabs.
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let window = NSApp.keyWindow ?? SessionsAPI.mainWindow().map({ $0.tabGroup?.selectedWindow ?? $0 })
            else { return (404, ["error": "no window"]) }
            _ = TerminalController.newTab(appDelegate.ghostty, from: window)
            return (200, ["ok": true])
        case ("POST", "/merge"):
            return (200, ["moved": SessionsAPI.mergeAll()])
        case ("GET", "/screenshot"):
            // For checking the sidebar without taking the user's screen: renders a window to PNG.
            let windows = SessionsAPI.allControllers().compactMap { $0.window }.filter { $0.isVisible }
            guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first,
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

    static func allControllers() -> [BaseTerminalController] {
        NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
    }

    static func allSurfaces() -> [Ghostty.SurfaceView] {
        allControllers().flatMap { $0.surfaceTree.root?.leaves() ?? [] }
    }

    private func surface(_ id: String?) -> Ghostty.SurfaceView? {
        guard let id else { return nil }
        return SessionsAPI.allSurfaces().first(where: { $0.id.uuidString == id })
    }

    // MARK: One window, every session a set of tabs in it

    /// The tab of each session you used last (session id → window number).
    static var lastActive: [String: Int] = [:]

    static func trackActiveTabs() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      let controller = window.windowController as? TerminalController else { return }
                lastActive[controller.sessionsWorkspace] = window.windowNumber
            }
        }
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
        let windows = allControllers().filter { $0 is TerminalController }.compactMap { $0.window }
            .filter { $0.isVisible && !$0.isMiniaturized }
        return windows.max { ($0.tabGroup?.windows.count ?? 1) < ($1.tabGroup?.windows.count ?? 1) }
    }

    /// Show a session without giving its terminal the keyboard.
    static func bringFront(_ view: Ghostty.SurfaceView) {
        guard let window = BaseTerminalController.controller(owning: view)?.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
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
        let key = NSApp.keyWindow
        var out: [[String: Any]] = []
        for controller in SessionsAPI.allControllers() {
            let tab = ScriptTab.stableID(controller: controller)
            let ws = (controller as? TerminalController)?.sessionsWorkspace ?? ""
            let tabTitle = controller.window?.title ?? ""
            for view in controller.surfaceTree.root?.leaves() ?? [] {
                out.append([
                    "id": view.id.uuidString,
                    "tab": tab,
                    "ws": ws,
                    "tab_title": tabTitle,
                    "title": view.titleOverride ?? view.title,
                    // What the program in the terminal set (Claude's own title), even under a fixed title.
                    "program_title": view.title,
                    "tty": view.surfaceModel?.ttyName ?? "",
                    "pid": view.surfaceModel?.foregroundPID ?? 0,
                    "cwd": view.pwd ?? "",
                    "focused": controller.window === key && controller.focusedSurface === view,
                    "surfaces_in_tab": controller.surfaceTree.root?.leaves().count ?? 1,
                ])
            }
        }
        return out
    }

    private func newTab(_ json: [String: Any]) -> (Int, Any) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return (500, ["error": "no app"]) }
        var config = Ghostty.SurfaceConfiguration()
        if let cwd = json["cwd"] as? String, !cwd.isEmpty { config.workingDirectory = cwd }
        if let input = json["input"] as? String, !input.isEmpty { config.initialInput = input }
        if let env = json["env"] as? [String: String] { config.environmentVariables = env }
        let focus = (json["focus"] as? Bool) ?? true
        // One window holds every session, like cmux: a new session is a new tab at the
        // end of it (the macOS tab bar is hidden; the sidebar and the panel show them).
        let host = SessionsAPI.mainWindow()
        let previous = host?.tabGroup?.selectedWindow ?? host
        let controller: TerminalController
        if let host, let tab = TerminalController.newTab(appDelegate.ghostty, from: host.tabGroup?.windows.last ?? host,
                                                          withBaseConfig: config) {
            controller = tab
        } else {
            controller = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config)
        }
        controller.sessionsWorkspace = UUID().uuidString
        if !focus, let previous, previous !== controller.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previous.tabGroup?.selectedWindow = previous
                previous.makeKeyAndOrderFront(nil)
            }
        }
        guard let view = controller.surfaceTree.root?.leaves().first else { return (500, ["error": "no surface"]) }
        if let title = json["title"] as? String, !title.isEmpty { view.titleOverride = title }
        if (json["split"] as? Bool) == true {
            var shell = Ghostty.SurfaceConfiguration()
            shell.workingDirectory = config.workingDirectory
            _ = controller.newSplit(at: view, direction: .right, baseConfig: shell)
            controller.focusSurface(view)
        }
        return (200, ["id": view.id.uuidString, "tab": ScriptTab.stableID(controller: controller), "ws": controller.sessionsWorkspace])
    }
}

