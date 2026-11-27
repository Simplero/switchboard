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
                    if req.method == "POST", req.path == "/sb/convsearch", req.headers["x-token"] == self.token {
                        // For checks: what the sidebar search answers ({"q": "words"}): the name
                        // results ("s") and "Search inside conversations" ("conv").
                        Task { @MainActor in
                            let q = req.json["q"] as? String ?? ""
                            var r = await Switchboard.shared.searchConversations(q)
                            r["s"] = Switchboard.shared.search(q)
                            self.respond(conn, status: 200, body: r)
                        }
                        return
                    }
                    if req.path == "/sb/convindex", req.headers["x-token"] == self.token {
                        // For checks: the conversation index. {"pass": true} reads what changed now and
                        // waits; {"key": "codex:<id>"} gives one conversation and its warning.
                        let pass = req.json["pass"] as? Bool == true, key = req.json["key"] as? String
                        Task.detached(priority: .userInitiated) {
                            let t0 = Date()
                            if pass { SBHistory.shared.passNow() }
                            let st = SBHistory.shared.status
                            var body: [String: Any] = ["home": SBHistory.shared.home ?? NSNull(), "db": SBHistory.shared.dbPath,
                                                       "busy": st.busy, "done": st.done, "todo": st.todo, "docs": st.docs,
                                                       "last_pass_seconds": st.lastPassSeconds, "waited": Date().timeIntervalSince(t0),
                                                       "db_bytes": (try? FileManager.default.attributesOfItem(atPath: SBHistory.shared.dbPath)[.size]) ?? 0]
                            if let key, let d = SBHistory.shared.doc(key) {
                                body["doc"] = ["title": d.title, "cwd": d.cwd ?? "", "branch": d.branch ?? "", "mtime": d.mtime,
                                               "machine": d.machine ?? "", "this_mac": d.thisMac.map { $0 as Any } ?? NSNull(), "path": d.path]
                                body["warning"] = SBHistory.shared.otherMacWarning(d) ?? NSNull()
                            }
                            await MainActor.run { self.respond(conn, status: 200, body: body) }
                        }
                        return
                    }
                    if req.method == "POST", req.path == "/sb/eval", req.headers["x-token"] == self.token {
                        // For checks: run JavaScript in the sidebar or the panel page (or, with "pane":
                        // <terminal id>, the page next to that terminal's session) and return its result.
                        let page = req.json["page"] as? String == "banner" ? SessionsWeb.banner : SessionsWeb.shared
                        var web: WKWebView = page.webView
                        if let pid = req.json["pane"] as? String, let view = SessionsAPI.surface(id: pid),
                           let controller = BaseTerminalController.controller(owning: view) as? TerminalController,
                           let doc = SessionsDocPanes.shared.pages[controller.sessionsWorkspace] { web = doc.webView }
                        web.callAsyncJavaScript(req.json["js"] as? String ?? "", arguments: [:], in: nil, in: .page) { result in
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
                    if req.method == "POST", req.path == "/sb/webwatch", req.headers["x-token"] == self.token {
                        // For checks: this app's WebKit GPU processes; {"stop": true} stops them the
                        // way the sidebar watch does when the sidebar does not draw.
                        let before = SBWebWatch.gpuProcesses()
                        let stopped = req.json["stop"] as? Bool == true ? SBWebWatch.stopGPU() : []
                        self.respond(conn, status: 200, body: ["gpu": before.map { Int($0) }, "stopped": stopped.map { Int($0) }])
                        return
                    }
                    if req.method == "POST", req.path == "/sb/tool", req.headers["x-token"] == self.token {
                        // For checks: ⌘B / ⌘I ({"kind": "board"|"session"}), as the keys do; {} closes it.
                        if let k = (req.json["kind"] as? String).flatMap(SBToolPage.Kind.init(rawValue:)) { SessionsDocPanes.shared.toggle(k) }
                        else { SessionsDocPanes.shared.tool = nil }
                        self.respond(conn, status: 200, body: ["tool": SessionsDocPanes.shared.tool ?? ""])
                        return
                    }
                    if req.method == "POST", req.path == "/sb/tooljs", req.headers["x-token"] == self.token {
                        // For checks: run JS in a tool page ({"page": "board", "js": "..."}), as clicks there would.
                        let kind = (req.json["page"] as? String).flatMap(SBToolPage.Kind.init(rawValue:)) ?? .board
                        let web = SessionsDocPanes.shared.toolPage(kind).webView
                        // {"click": [x, y]}: first a real mouse click at that point of the page.
                        if let xy = req.json["click"] as? [Double], xy.count == 2, let w = web.window {
                            let p = web.convert(NSPoint(x: xy[0], y: web.isFlipped ? xy[1] : web.bounds.height - xy[1]), to: nil)
                            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                                if let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                                    switch type {
                                    case .mouseMoved: web.mouseMoved(with: ev)
                                    case .leftMouseDown: web.mouseDown(with: ev)
                                    default: web.mouseUp(with: ev)
                                    }
                                }
                                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                            }
                        }
                        web.evaluateJavaScript(req.json["js"] as? String ?? "") { out, err in
                            Task { @MainActor in
                                self.respond(conn, status: err == nil ? 200 : 500, body: ["out": out.map { "\($0)" } ?? "", "error": err.map { "\($0)" } ?? ""])
                            }
                        }
                        return
                    }
                    if req.method == "GET", req.path == "/sb/snap", req.headers["x-token"] == self.token {
                        // For checks: a picture of the sidebar or the panel page (window pictures leave web views blank).
                        // ?page=board / session: that tool page.
                        let page = req.query["page"] == "banner" ? SessionsWeb.banner : SessionsWeb.shared
                        var web: WKWebView = page.webView
                        if let t = req.query["page"].flatMap(SBToolPage.Kind.init(rawValue:)) { web = SessionsDocPanes.shared.toolPage(t).webView }
                        // ?pane=<terminal id>: the page next to that terminal's session.
                        if let pid = req.query["pane"], let view = SessionsAPI.surface(id: pid),
                           let controller = BaseTerminalController.controller(owning: view) as? TerminalController,
                           let doc = SessionsDocPanes.shared.pages[controller.sessionsWorkspace] { web = doc.webView }
                        web.takeSnapshot(with: nil) { image, _ in
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
        if req.method == "POST", !req.path.hasPrefix("/sb/history") {
            SessionSwitchLog.because("the API: \(req.path)" + ((req.json["op"] as? String).map { " \($0)" } ?? ""))
        }
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
        case ("POST", "/sb/boardmove"):
            // For checks: what the panel's Board menu does. {"k", "col"}; no col takes it off.
            guard let k = req.json["k"] as? String else { return (400, ["error": "k"]) }
            SBBoard.shared.move(k, to: req.json["col"] as? String)
            return (200, ["board": SBBoard.shared.summary])
        case ("POST", "/sb/sessionmenu"):
            // For checks: the sidebar's right-click menu of a session ({"k"}), as titles; with
            // "pick": ["Submenu", "Item"], it runs that item as a click would.
            guard let k = req.json["k"] as? String,
                  let s = SessionsStore.shared.payload?.s.first(where: { $0.k == k }) else { return (400, ["error": "k"]) }
            let menu = SessionsWeb.shared.sessionMenu(for: s)
            func rows(_ m: NSMenu) -> [Any] {
                m.items.filter { !$0.isSeparatorItem }.map { it in
                    let t = (it.state == .on ? "✓ " : "") + it.title + (it.action == nil && it.submenu == nil ? " (off)" : "")
                    return it.submenu.map { [t: rows($0)] as Any } ?? t
                }
            }
            if let pick = req.json["pick"] as? [String], !pick.isEmpty {
                var m = menu
                for (n, title) in pick.enumerated() {
                    guard let i = m.items.firstIndex(where: { $0.title == title }) else { return (404, ["error": "no item \(title)"]) }
                    if n == pick.count - 1 { m.performActionForItem(at: i) } else if let sub = m.items[i].submenu { m = sub }
                }
                return (200, ["picked": pick, "board": SBBoard.shared.summary])
            }
            return (200, ["menu": rows(menu)])
        case ("POST", "/sb/boardprio"):
            // For checks: mark a session ({"k", "on"}) or a column ({"col", "on"}) as a priority.
            let on = req.json["on"] as? Bool ?? true
            if let k = req.json["k"] as? String {
                SBBoard.shared.setPriority(k, on)
            } else if let col = req.json["col"] as? String {
                var state = SBBoard.shared.json
                state["cols"] = ((state["cols"] as? [[String: Any]]) ?? []).map { c in
                    var c = c
                    if c["id"] as? String == col { if on { c["prio"] = true } else { c.removeValue(forKey: "prio") } }
                    return c
                }
                SBBoard.shared.save(state)
            } else { return (400, ["error": "k or col"]) }
            return (200, ["board": SBBoard.shared.json])
        case ("POST", "/sb/restart"):
            // For checks: what "Restart to update" does, without the question.
            Task { @MainActor in SessionsVersion.shared.restart(confirm: false) }
            return (200, ["ok": true])
        case ("POST", "/sb/badgecheck"):
            // For checks: the box that shows files going to another machine, on a terminal
            // (?id=), at `sent` of `total` bytes (no `sent`: still connecting). Returns its picture.
            guard let view = surface(req.json["id"] as? String) else { return (404, ["error": "no such terminal"]) }
            let total = Int64(req.json["total"] as? Int ?? 0)
            guard let b = SBTransferBadge.show(on: view, what: req.json["what"] as? String ?? "clip.mov", machine: "om01", total: total) else { return (500, ["error": "no box"]) }
            if let sent = req.json["sent"] as? Int { b.update(sent: Int64(sent)) }
            view.layoutSubtreeIfNeeded()
            let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds)
            if let rep { b.cacheDisplay(in: b.bounds, to: rep) }
            let png = rep?.representation(using: .png, properties: [:])
            let frame = b.frame
            b.finish()
            return (200, ["png": (png?.base64EncodedString() as Any?) ?? NSNull(), "frame": [frame.minX, frame.minY, frame.width, frame.height], "view": [view.bounds.width, view.bounds.height]])
        case ("GET", "/sb/termshot"):
            // For checks: what a terminal drew (?id=, or ?spare=<login dir>), read from its
            // layer, without a screen capture.
            let view = surface(req.query["id"]) ?? req.query["spare"].flatMap { SBSpares.shared.spares[$0]?.view }
            guard let view else { return (404, ["error": "no such terminal"]) }
            guard let png = SessionsAPI.drawnPicture(view) else { return (200, ["png": NSNull(), "note": "nothing drawn yet"]) }
            return (200, ["png": png.base64EncodedString()])
        case ("GET", "/sb/promptcheck"):
            // For checks: what Move to folder reads in a terminal (?id=): its prompt, the cursor,
            // background work, and (?k=) why that session cannot move yet ("free" when it can).
            guard let view = surface(req.query["id"]) else { return (404, ["error": "no such terminal"]) }
            let text = SessionsAPI.activeText(of: view) ?? ""
            let c = SessionsAPI.cursor(of: view)
            var out: [String: Any] = ["prompt": SBScreen.promptText(text) ?? NSNull(), "background": SBScreen.backgroundBusy(text),
                                      "cursor": c.map { [$0.row, $0.col] } ?? [], "row": c.flatMap { SessionsAPI.rowText(of: view, $0.row) } ?? NSNull()]
            if let k = req.query["k"] { out["blocker"] = Switchboard.shared.moveCheck(k) }
            return (200, out)
        case ("POST", "/sb/clickcheck"):
            // For checks: move the mouse to a cell of a terminal and click it, with ⌘ when
            // "mods" is "command" ({"id", "row", "col"}); then the links a test copy would have opened.
            guard let view = surface(req.json["id"] as? String), let s = view.surface, let w = view.window else { return (404, ["error": "no such terminal"]) }
            let size = ghostty_surface_size(s)
            let scale = Double(w.backingScaleFactor)
            let cw = Double(size.cell_width_px) / scale, ch = Double(size.cell_height_px) / scale
            var row = Double(req.json["row"] as? Int ?? 0), col = Double(req.json["col"] as? Int ?? 0)
            if let needle = req.json["find"] as? String {
                // The last row of the active area with this text, and a cell inside it.
                var found = false
                for r in stride(from: Int(size.rows) - 1, through: 0, by: -1) {
                    if let t = SessionsAPI.rowText(of: view, r), let range = t.range(of: needle) {
                        row = Double(r); col = Double(t.distance(from: t.startIndex, to: range.lowerBound) + 2); found = true; break
                    }
                }
                if !found { return (404, ["error": "text not on the screen"]) }
            }
            let pad = req.json["pad"] as? Double ?? 2
            let local = NSPoint(x: pad + (col + 0.5) * cw, y: view.isFlipped ? pad + (row + 0.5) * ch : view.bounds.height - pad - (row + 0.5) * ch)
            let p = view.convert(local, to: nil)
            let mods: NSEvent.ModifierFlags = req.json["mods"] as? String == "command" ? [.command] : []
            SessionsLinkOpener.lastOpened = []
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                switch type {
                case .mouseMoved: view.mouseMoved(with: ev)
                case .leftMouseDown: view.mouseDown(with: ev)
                default: view.mouseUp(with: ev)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            return (200, ["opened": SessionsLinkOpener.lastOpened, "cell": [cw, ch], "grid": [Int(size.columns), Int(size.rows)]])
        case ("POST", "/sb/askcheck"):
            // For checks: which login Switchboard's own Claude calls use. {"usage": {login: {"h5": {"p": 40}, "wk": {"p": 100}}}}
            if let u = req.json["usage"] as? [String: Any] { SBBackground.setOwnUsage(u) }
            let order = SBBackground.ownLogins()
            let out = req.json["run"] as? Bool == true ? SBBackground.ask("haiku", "Say ok", timeout: 20) : nil
            return (200, ["order": order, "out": out as Any? ?? NSNull(), "used": SBBackground.ownLast as Any? ?? NSNull(), "after": SBBackground.ownLogins()])
        case ("POST", "/sb/keycheck"):
            // For checks: press a key with ⌘ (or ⌃) on the sidebar page the way AppKit dispatches it
            // (local monitors, the window's views, then the menu). {"key": "v"}
            // ?pane=<terminal id>: the page next to that terminal's session instead of the sidebar.
            var web: WKWebView = SessionsWeb.shared.webView
            if let pid = req.json["pane"] as? String, let view = surface(pid),
               let controller = BaseTerminalController.controller(owning: view) as? TerminalController,
               let page = SessionsDocPanes.shared.pages[controller.sessionsWorkspace] { web = page.webView }
            guard var w = web.window else { return (404, ["error": "no window for that page"]) }
            // With a terminal for the keyboard: that terminal's window.
            if let tid = req.json["responder_terminal"] as? String, let tw = surface(tid)?.window { w = tw }
            if req.json["handover"] as? Bool == true, let tid = req.json["responder_terminal"] as? String {
                // What ⌘V does in a session on another machine (a test copy is never the active
                // app, so Ghostty's own ⌘V binding takes the key there first).
                return (200, ["handed_over": Switchboard.shared.handOverClipboard(surface: tid)])
            }
            if req.json["click"] as? Bool == true {
                // A click in the middle of the page, the way AppKit dispatches it (monitors first).
                let p = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let m = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(m) }
                }
            }
            if let tid = req.json["responder_terminal"] as? String, let tv = surface(tid) {
                // As when the terminal takes the keyboard back (its window came forward).
                w.makeFirstResponder(tv)
            } else if req.json["click"] as? Bool != true, req.json["keep"] as? Bool != true {   // keep: whatever has the keyboard keeps it
                w.makeFirstResponder(web)
            }
            let ch = req.json["key"] as? String ?? "v"
            let arrows: [String: (UInt16, String)] = ["up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}")]
            let code: UInt16 = arrows[ch]?.0 ?? ["v": 9, "c": 8, "x": 7, "a": 0, "f": 3, "g": 5, "1": 18, "2": 19, "3": 20, "=": 24, "-": 27, "0": 29][ch] ?? 9
            // "mods": "control" for ⌃ (the pins' keys) instead of ⌘.
            let mods: NSEvent.ModifierFlags = req.json["mods"] as? String == "control" ? [.control] : [.command]
            let chars = arrows[ch]?.1 ?? ch
            guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) else { return (500, ["error": "no event"]) }
            if req.json["send"] as? Bool == true {
                // Through the app's whole key path (its key monitors first).
                NSApp.sendEvent(ev)
                return (200, ["sent": true, "focused": (SessionsStore.shared.focusedSurfaceID as Any?) ?? NSNull()])
            }
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
        case ("POST", "/sb/openlink"):
            // A link a program in one of the terminals opened ($BROWSER, see SessionsLinkHelper):
            // a Simplero Doc opens next to that terminal's session, anything else where Link
            // Router sends it. {"url", "tty", "dry"?}
            guard let url = URL(string: (req.json["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)),
                  url.scheme != nil else { return (400, ["error": "no url"]) }
            let tty = (req.json["tty"] as? String ?? "").replacingOccurrences(of: "/dev/", with: "")
            let term = tty.isEmpty ? nil : SessionsAPI.terminalList().first { $0.tty.hasSuffix("/" + tty) || $0.tty == tty }
            let session = term.flatMap { surface($0.id) }.flatMap { BaseTerminalController.controller(owning: $0) as? TerminalController }?.sessionsWorkspace
            let ws = session ?? SessionsDocPanes.frontSession
            let route = SessionsDocPanes.isDoc(url) && ws != nil ? "pane" : "browser"
            if req.json["dry"] as? Bool != true {
                if route == "pane", let ws { SessionsDocPanes.shared.open(url, session: ws) } else { SessionsLinkOpener.open(url, nextToSession: false) }
            }
            return (200, ["route": route, "session": (ws as Any?) ?? NSNull(), "terminal": (term?.id as Any?) ?? NSNull()])
        case ("POST", "/sb/docpane"):
            // For checks: open a page next to the session of a terminal (?id), as a Doc link does.
            guard let view = surface(req.json["id"] as? String),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController,
                  let url = URL(string: req.json["url"] as? String ?? "about:blank") else { return (404, ["error": "no such terminal"]) }
            if req.json["close"] as? Bool == true { SessionsDocPanes.shared.close(session: controller.sessionsWorkspace) }
            else if let q = req.json["find"] as? String, let page = SessionsDocPanes.shared.pages[controller.sessionsWorkspace] {
                // Find on the page as the find bar does: {"find": text, "back": true} (no url needed).
                page.openFind()
                page.findText = q
                page.find(backwards: req.json["back"] as? Bool == true)
            } else if req.json["endfind"] as? Bool == true { SessionsDocPanes.shared.pages[controller.sessionsWorkspace]?.closeFind() }
            else { SessionsDocPanes.shared.open(url, session: controller.sessionsWorkspace) }
            return (200, ["session": controller.sessionsWorkspace, "tool": SessionsDocPanes.shared.tool ?? ""])
        case ("POST", "/sb/dragcheck"):
            // For checks: drag the page pane's divider by dx points with real mouse events.
            guard let view = surface(req.json["id"] as? String),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController,
                  let page = SessionsDocPanes.shared.pages[controller.sessionsWorkspace],
                  let w = page.webView.window else { return (404, ["error": "no pane"]) }
            let dx = CGFloat(req.json["dx"] as? Double ?? -200)
            let paneFrame = page.webView.convert(page.webView.bounds, to: nil)
            var start = NSPoint(x: paneFrame.minX - 3.5, y: paneFrame.midY)   // the middle of the 7-point handle
            if req.json["sidebar"] as? Bool == true {
                let side = SessionsWeb.shared.webView
                let f = side.convert(side.bounds, to: nil)
                start = NSPoint(x: f.maxX + 3.5, y: f.midY)
            }
            if let x = req.json["x"] as? Double { start.x = CGFloat(x) }
            let hit = w.contentView?.superview?.hitTest(start) ?? w.contentView?.hitTest(start)
            let before = paneFrame.width
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            if let e = mouse(.leftMouseDown, start) { w.sendEvent(e) }
            for i in 1...10 { if let e = mouse(.leftMouseDragged, NSPoint(x: start.x + dx * CGFloat(i) / 10, y: start.y)) { w.sendEvent(e) } }
            if let e = mouse(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y)) { w.sendEvent(e) }
            return (200, ["before": before, "divider_x": start.x, "hit": hit.map { String(describing: type(of: $0)) } ?? "none",
                          "sidebar_width": UserDefaults.standard.double(forKey: "sessions.sidebar.width"),
                          "pane_width_saved": UserDefaults.standard.double(forKey: "sessions.docpane.width")])
        case ("GET", "/sb/docpane"):
            // For checks: the page next to a terminal's session, its size, and the terminal's grid.
            guard let view = surface(req.query["id"]),
                  let controller = BaseTerminalController.controller(owning: view) as? TerminalController else { return (404, ["error": "no such terminal"]) }
            let page = SessionsDocPanes.shared.pages[controller.sessionsWorkspace]
            return (200, ["open": page != nil, "title": page?.title ?? "", "url": page?.webView.url?.absoluteString ?? "",
                          "finding": page?.finding ?? false, "find_text": page?.findText ?? "", "find_result": page?.findResult ?? "",
                          "keyboard": SessionsAPI.keyboardOwner(controller.window),
                          "find_selection": SessionsAPI.selection(controller.window),
                          "in_window": page?.webView.window === controller.window,
                          "pane_width": page?.webView.frame.width ?? 0,
                          "grid": SessionsAPI.gridSize(view).map { [$0.cols, $0.rows] } ?? []])
        case ("POST", "/sb/keytrace"):
            // For checks: who has the keyboard in the front tab, every 50 ms for {"ms": 2000}.
            SessionsAPI.keyTrace = []
            // {"give": "panel" | "sidebar"}: that page has the keyboard first, as after a click in it.
            if let give = req.json["give"] as? String {
                let web = give == "panel" ? SessionsWeb.banner.webView : SessionsWeb.shared.webView
                web.window?.makeFirstResponder(web)
            }
            // {"then": "newtab"}: a new tab in the front session, as + in the panel does.
            if req.json["then"] as? String == "newtab", let appDelegate = NSApp.delegate as? AppDelegate,
               let w = SessionsAPI.mainWindow() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    _ = TerminalController.newTab(appDelegate.ghostty, from: w.tabGroup?.selectedWindow ?? w)
                }
            }
            let start = Date()
            let ms = req.json["ms"] as? Double ?? 2000
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
                MainActor.assumeIsolated {
                    let el = Date().timeIntervalSince(start) * 1000
                    if el > ms { t.invalidate(); return }
                    let w = SessionsAPI.mainWindow()
                    let sel = w?.tabGroup?.selectedWindow ?? w
                    let line = "\(Int(el)) tab \(sel?.windowNumber ?? 0) key \(NSApp.keyWindow?.windowNumber ?? 0): \(SessionsAPI.responderName(sel?.firstResponder))"
                    if SessionsAPI.keyTrace.last.map({ $0.split(separator: " ", maxSplits: 1).last.map(String.init) != line.split(separator: " ", maxSplits: 1).last.map(String.init) }) ?? true {
                        SessionsAPI.keyTrace.append(line)
                    }
                }
            }
            return (200, ["ok": true])
        case ("GET", "/sb/keytrace"):
            let w = SessionsAPI.mainWindow()
            let sel = w?.tabGroup?.selectedWindow ?? w
            let surf = (sel?.windowController as? BaseTerminalController)?.surfaceTree.root?.leaves().map { String($0.id.uuidString.prefix(8)) } ?? []
            return (200, ["trace": SessionsAPI.keyTrace, "now": SessionsAPI.responderName(sel?.firstResponder), "tab_terminals": surf])
        case ("GET", "/sb/limits"), ("POST", "/sb/limits"):
            // For checks: the logins almost out and the login with room. POST {"use": {login:
            // {"wk": {"p", "r"}, "h5": {"p"}}}} sets plan usage until the next fetch (3 minutes).
            if req.method == "POST", let u = req.json["use"] as? [String: Any] { Switchboard.shared.setUsageForCheck(u) }
            return (200, ["full": Switchboard.shared.fullLogins, "room": (Switchboard.shared.loginWithRoom as Any?) ?? NSNull()])
        case ("GET", "/sb/switchlog"):
            // For checks: the end of the log of session switches, and the sidebar's away state.
            let text = (try? String(contentsOfFile: SessionSwitchLog.path, encoding: .utf8)) ?? ""
            return (200, ["lines": Array(text.split(separator: "\n").suffix(20).map(String.init)),
                          "moved_while_away": SessionsWebView.listMovedWhileAway,
                          "first_mouse": SessionsWeb.shared.webView.acceptsFirstMouse(for: nil),
                          "focused": (SessionsStore.shared.focusedSurfaceID as Any?) ?? NSNull()])
        case ("GET", "/sb/menukeys"):
            // For checks: the menu items that switch tabs (each session is a tab of the one window).
            var rows: [String] = []
            func walk(_ m: NSMenu, _ path: String) {
                for it in m.items {
                    let act = it.action.map { NSStringFromSelector($0) } ?? ""
                    if it.keyEquivalent == "\t" || act.lowercased().contains("tab") {
                        var mods = ""
                        if it.keyEquivalentModifierMask.contains(.control) { mods += "⌃" }
                        if it.keyEquivalentModifierMask.contains(.shift) { mods += "⇧" }
                        if it.keyEquivalentModifierMask.contains(.command) { mods += "⌘" }
                        rows.append("\(path) › \(it.title)  [\(mods)\(it.keyEquivalent == "\t" ? "⇥" : it.keyEquivalent)]  \(act)")
                    }
                    if let sub = it.submenu { walk(sub, path + " › " + it.title) }
                }
            }
            if let m = NSApp.mainMenu { walk(m, "") }
            if let wm = NSApp.windowsMenu {
                wm.update()
                for it in wm.items where !it.isSeparatorItem {
                    rows.append("Window › \(it.title) [\(it.keyEquivalentModifierMask.rawValue):\(it.keyEquivalent.unicodeScalars.map { String($0.value) }.joined(separator: ","))] \(it.action.map { NSStringFromSelector($0) } ?? "")")
                }
            }
            return (200, ["items": rows])
        case ("GET", "/sb/history"), ("POST", "/sb/history"):
            // For checks: back and forward between sessions. POST {visit: key} | {go: "back"|"forward"} |
            // {jump_back: i} | {jump_forward: i}; the answer is the state and the History menu's lines.
            let h = SessionHistory.shared
            if req.method == "POST" {
                if let k = req.json["visit"] as? String { h.visited(k) }
                switch req.json["go"] as? String { case "back": h.goBack("check: back"); case "forward": h.goForward("check: forward"); default: break }
                if let i = req.json["jump_back"] as? Int { h.jump(toBack: i, via: "check: History") }
                if let i = req.json["jump_forward"] as? Int { h.jump(toForward: i, via: "check: History") }
            }
            let menu = h.menu { title, checked, _ in let m = NSMenuItem(title: title, action: nil, keyEquivalent: ""); m.state = checked ? .on : .off; return m }
            return (200, ["back": h.back, "forward": h.forward, "current": (h.current as Any?) ?? NSNull(),
                          "can_back": h.canGoBack, "can_forward": h.canGoForward,
                          "menu": menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "") + $0.title }])
        case ("POST", "/sb/framecheck"):
            // For checks: the Switchboard window's frame (the tab in front and every tab), and a
            // way to move it the way a person would ({"set": [x, y, w, h]}) or to ask for a
            // spare like the new-session form does ({"want": login dir, "" for none}).
            guard let main = SessionsAPI.mainWindow() else { return (404, ["error": "no window"]) }
            let front = main.tabGroup?.selectedWindow ?? main
            if let f = req.json["set"] as? [Double], f.count == 4 {
                front.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true)
            }
            if let l = req.json["want"] as? String { SBSpares.shared.want(l.isEmpty ? nil : l) }
            if let a = req.json["appearance"] as? String {   // "dark", "light", "" (the system's)
                NSApp.appearance = a == "dark" ? NSAppearance(named: .darkAqua) : a == "light" ? NSAppearance(named: .aqua) : nil
                front.appearance = NSApp.appearance   // Ghostty gives the window its theme's look
            }
            func r(_ w: NSWindow) -> [Int] { [Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height)] }
            return (200, ["front": r(front), "tabs": (front.tabGroup?.windows ?? [front]).map(r),
                          "spares": SBSpares.shared.spares.values.compactMap { $0.controller.window }.map(r)])
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
    /// if something opened a second window), as its tab in front. Only that tab has the
    /// frame you see: a tab in the background keeps the frame it had when it was last in
    /// front, so a spare sized like it was too small, and a frame taken from it was old.
    static func mainWindow() -> NSWindow? {
        let all = allControllers().filter { $0 is TerminalController }.compactMap { $0.window }
        // Visible windows first; while the app starts hidden (a restart in the background),
        // any terminal window, so new sessions still join one window.
        let shown = all.filter { $0.isVisible || $0.isMiniaturized }
        let biggest = (shown.isEmpty ? all : shown).max { ($0.tabGroup?.windows.count ?? 1) < ($1.tabGroup?.windows.count ?? 1) }
        return biggest.map { $0.tabGroup?.selectedWindow ?? $0 }
    }

    /// Show a session: the tab of it you used last (a shell tab, say), else its own terminal.
    static func focus(_ view: Ghostty.SurfaceView) {
        guard let controller = BaseTerminalController.controller(owning: view) else { return }
        if let tc = controller as? TerminalController, let n = lastActive[tc.sessionsWorkspace],
           let last = NSApp.window(withWindowNumber: n), last !== controller.window,
           (last.windowController as? TerminalController)?.sessionsWorkspace == tc.sessionsWorkspace {
            last.tabGroup?.selectedWindow = last
            last.makeKeyAndOrderFront(nil)
            // The window may already be key (you clicked the sidebar in it): give the keyboard
            // back to its terminal, not the sidebar.
            if let lc = last.windowController as? BaseTerminalController, let sv = lc.focusedSurface { lc.focusSurface(sv) }
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

    private static let cupRE = try! NSRegularExpression(pattern: "\u{1b}\\[(\\d+);(\\d+)H")

    /// Where the cursor is in the active area (row and column, from 0). The terminal's saved
    /// state ends with the cursor position (CUP, the last one in it), then modes.
    static func cursor(of view: Ghostty.SurfaceView) -> (row: Int, col: Int)? {
        guard let s = view.surface else { return nil }
        let state = ghostty_surface_dump_vt(s)
        defer { ghostty_string_free(state) }
        guard let p = state.ptr, state.len > 0 else { return nil }
        let n = Int(state.len), from = max(0, n - 65_536)
        let tail = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(p + from), count: n - from), as: UTF8.self)
        guard let m = cupRE.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
              let r = Range(m.range(at: 1), in: tail), let c = Range(m.range(at: 2), in: tail),
              let row = Int(tail[r]), let col = Int(tail[c]), row >= 1, col >= 1 else { return nil }
        return (row - 1, col - 1)
    }

    /// One row of the active area, as text.
    static func rowText(of view: Ghostty.SurfaceView, _ row: Int) -> String? {
        guard let s = view.surface, row >= 0 else { return nil }
        let cols = Int(ghostty_surface_size(s).columns)
        guard cols > 0 else { return nil }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(cols - 1), y: UInt32(row)),
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

    /// Put the keyboard in this terminal: its own tab in front (not the tab of its session
    /// you used last), and it keeps the keyboard while the tab settles (see keepKeyboard).
    static func focusTerminal(_ id: String) {
        guard let view = surface(id: id), let controller = BaseTerminalController.controller(owning: view) else { return }
        if let window = controller.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        controller.focusSurface(view)
        view.window?.makeFirstResponder(view)
        keepKeyboard(id)
    }

    private static var lastClick = Date.distantPast
    private static var clickMonitor: Any?

    /// For a moment after Switchboard opens or selects a terminal, the keyboard stays in it.
    /// The sidebar and panel pages move into the window in front, and the page you clicked
    /// (+ in the panel, a row, a menu) can take the keyboard back while the new tab settles;
    /// a window that was key already does not hand it on by itself. Only from those pages, or
    /// from nothing: a click of yours after it opened, another tab, or the new-session form
    /// ends it.
    static func keepKeyboard(_ id: String, for seconds: Double = 1.2) {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                lastClick = Date()
                return event
            }
        }
        let start = Date()
        func check() {
            guard Date().timeIntervalSince(start) < seconds, lastClick < start,
                  let v = surface(id: id), let w = v.window, (w.tabGroup?.selectedWindow ?? w) === w else { return }
            if w.firstResponder !== v, !SessionsWebView.newFormOpen {
                let r = w.firstResponder
                let pages: [NSView] = [SessionsWeb.shared.webView, SessionsWeb.banner.webView]
                let ours = r == nil || r === w || pages.contains { p in (r as? NSView).map { $0 === p || $0.isDescendant(of: p) } == true }
                guard ours else { return }     // a field or a terminal you chose: leave it there
                w.makeFirstResponder(v)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { check() } }
        }
        check()
    }

    /// A spare (SBSpares, Claude already at its prompt) becomes a new session: the last
    /// tab of the one window, in front. Like `openTab`, without the wait for Claude.
    static func adoptSpare(_ controller: TerminalController) -> (id: String, tab: String, ws: String)? {
        guard let window = controller.window, let view = controller.surfaceTree.root?.leaves().first,
              let host = mainWindow() else { return nil }
        // The window keeps the place and size you gave it: the spare joins with that frame.
        let frame = host.frame
        if window.frame != frame { window.setFrame(frame, display: false) }
        let last = host.tabGroup?.windows.last ?? host
        guard last.addTabbedWindowSafely(window, ordered: .above) else { return nil }
        controller.sessionsWorkspace = UUID().uuidString
        SessionSwitchLog.because("a new session")
        last.tabGroup?.selectedWindow = window
        controller.showWindowSafely(nil)
        if window.frame != frame { window.setFrame(frame, display: true) }
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
    /// For checks: what has the keyboard in a window ("find field", "page", "terminal", or the view's type).
    static var keyTrace: [String] = []

    /// For checks: who has the keyboard, in words.
    static func responderName(_ r: NSResponder?) -> String {
        guard let r else { return "nothing" }
        if let v = r as? Ghostty.SurfaceView { return "terminal " + v.id.uuidString.prefix(8) }
        if let v = r as? NSView {
            if v === SessionsWeb.shared.webView || v.isDescendant(of: SessionsWeb.shared.webView) { return "sidebar page" }
            if v === SessionsWeb.banner.webView || v.isDescendant(of: SessionsWeb.banner.webView) { return "panel page" }
            if v is DocWebView || v.enclosingDocWebView != nil { return "doc page" }
        }
        if r is NSWindow { return "the window" }
        return String(describing: type(of: r))
    }

    static func keyboardOwner(_ w: NSWindow?) -> String {
        guard let r = w?.firstResponder else { return "nothing" }
        if let editor = r as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            return field.placeholderString == "Find on this page" ? "find field" : "field \(field.placeholderString ?? "")"
        }
        if let v = r as? NSView, v is DocWebView || v.enclosingDocWebView != nil { return "page" }
        if r is Ghostty.SurfaceView { return "terminal" }
        return String(describing: type(of: r))
    }

    /// For checks: the selected range in the text that has the keyboard.
    static func selection(_ w: NSWindow?) -> [Int] {
        guard let t = w?.firstResponder as? NSTextView else { return [] }
        let r = t.selectedRange()
        return [r.location, r.length]
    }

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
        SessionSwitchLog.did(parent == nil ? "a new session tab" : "a new tab in a session")
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

