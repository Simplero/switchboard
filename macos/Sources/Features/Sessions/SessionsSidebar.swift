import AppKit
import SwiftUI

// The sessions sidebar: every coding-agent session (open or closed) in two
// columns that scroll on their own, each with its own filter, grouping and
// sort. Data comes from the session helper at http://127.0.0.1:4477
// (~/code/session-inbox/server.py); actions go back to it as JSON.

// MARK: - Data from the helper

struct SessionItem: Decodable, Identifiable, Equatable {
    let k: String
    let n: String
    let c: String?
    let lb: [String]?
    let lg: String?
    let ld: String?
    let a: String?
    let st: String?
    let u: Bool?
    let ns: String?
    let t: String?
    let ws: String?
    let sf: String?
    let o: Bool?
    let pk: Bool?
    let la: Int?
    let ca: Int?
    let cwd: String?
    let br: String?
    let rm: String?
    let rp: [[String]]?
    let art: [String]?
    let be: String?
    let sd: String?
    let lm: String?
    let wl: String?
    let ar: Bool?

    var id: String { k }
    var isOpen: Bool { o ?? false }
    var isParked: Bool { pk ?? false }
    var isArchived: Bool { ar ?? false }
    var labels: [String] { lb ?? [] }
    var login: String { lg ?? "" }
}

struct SpareInfo: Decodable, Equatable {
    let lg: String
    let ready: Bool
    let warming: Bool?
}

struct GroupInfo: Decodable, Equatable {
    let id: String?
    let name: String?
    let members: [String]?
}

struct OtherWorkspace: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
}

struct SidebarPayload: Decodable, Equatable {
    let at: Int
    let classes: [String]?
    let labels: [String]?
    let spares: [String: SpareInfo]?
    let s: [SessionItem]
    let grp: [GroupInfo]?
    let ot: [OtherWorkspace]?
}

@MainActor
final class SessionsStore: ObservableObject {
    static let shared = SessionsStore()

    @Published var payload: SidebarPayload?
    @Published var helperUp = false
    @Published var focusedSurfaceID: String?
    @Published var now = Int(Date().timeIntervalSince1970)
    /// A clicked row highlights at once; cleared when focus catches up.
    @Published var picked: String?

    private var timer: Timer?
    private var keyMonitor: Any?
    /// The left column's session order, for ⌘↑ / ⌘↓.
    var navOrder: [String] = []
    private var startedHelper = false
    private var failures = 0
    private let base = URL(string: "http://127.0.0.1:4477")!

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        SessionsWindowStack.start()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFocus() }
        }
        // ⌘↑ / ⌘↓: previous / next session.  ⌘P: search.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command {
                // Arrows by key code (the same on every layout). Letters by the
                // character the layout types: key code 35 is P only on QWERTY
                // (on Dvorak it is L, and Dvorak P is key code 15).
                if event.keyCode == 126 { self.step(-1); return nil }   // up arrow
                if event.keyCode == 125 { self.step(1); return nil }    // down arrow
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "p":
                    if UserDefaults.standard.object(forKey: "sessions.sidebar.web") as? Bool ?? true {
                        UserDefaults.standard.set(true, forKey: "sessions.sidebar.visible")
                        SessionsWeb.shared.focusSearch()
                    } else {
                        NotificationCenter.default.post(name: .sessionsFocusSearch, object: nil)
                    }
                    return nil
                case "n" where self.helperUp:
                    // ⌘N: a new session with a plain shell (no agent), not a bare window.
                    self.newShellSession()
                    return nil
                default: break
                }
            }
            return event
        }
        tick()
    }

    /// A new session window with a plain shell, in the folder of the terminal you are in.
    func newShellSession() {
        let pwd = (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface?.pwd
        send(["op": "new_shell", "cwd": pwd ?? "~"])
    }

    /// When you last looked at each session (session key → time). Drives "Visited" sort.
    @Published var visits: [String: Double] = (UserDefaults.standard.dictionary(forKey: "sessions.visits") as? [String: Double]) ?? [:]

    private func recordVisit() {
        guard let id = focusedSurfaceID, NSApp.isActive,
              let s = payload?.s.first(where: { $0.sf == id && $0.isOpen }) else { return }
        let now = Date().timeIntervalSince1970
        if let last = visits[s.k], now - last < 30 { visits[s.k] = now; return }
        visits[s.k] = now
        UserDefaults.standard.set(visits, forKey: "sessions.visits")
    }

    func refreshFocus() {
        let controller = NSApp.keyWindow?.windowController as? BaseTerminalController
        let id = controller?.focusedSurface?.id.uuidString
        if id != focusedSurfaceID {
            focusedSurfaceID = id
            SessionsWeb.shared.setFocus(id)
            SessionsWeb.banner.pushBannerContext()
        }
        recordVisit()
        if let p = picked, let s = payload?.s.first(where: { $0.k == p }), s.sf == id { picked = nil }
    }

    private func tick() {
        now = Int(Date().timeIntervalSince1970)
        refreshFocus()
        SessionsWeb.banner.pushBannerContext()
        var req = URLRequest(url: base.appendingPathComponent("api/sidebar"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, error in
            let decoded = data.flatMap { try? JSONDecoder().decode(SidebarPayload.self, from: $0) }
            Task { @MainActor in
                if let decoded {
                    if decoded != self.payload { self.payload = decoded }
                    self.helperUp = true
                    self.failures = 0
                    if UserDefaults.standard.bool(forKey: "sessions.restoreAfterRestart") {
                        UserDefaults.standard.set(false, forKey: "sessions.restoreAfterRestart")
                        // The app opens one empty shell window at launch. After a restart the
                        // sessions come back in their own windows, so close that empty one.
                        let initial = NSApp.windows.filter { $0.windowController is BaseTerminalController }
                        self.send(["op": "restore_after_restart"]) { ok in
                            guard ok else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.closeUntouched(initial) }
                        }
                    }
                } else {
                    self.helperUp = false
                    // Only start our own helper after 20 s with nobody on the port:
                    // the one inside cmux is preferred, because only it can see cmux.
                    if error != nil { self.failures += 1 }
                    if self.failures >= 20 { self.startHelperIfNeeded() }
                }
            }
        }.resume()
    }

    /// Start the helper once if nothing answers on its port.
    private func startHelperIfNeeded() {
        guard !startedHelper else { return }
        startedHelper = true
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code/session-inbox/server.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path]
        p.currentDirectoryURL = script.deletingLastPathComponent()
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/session-inbox/helper.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: log) {
            p.standardOutput = fh
            p.standardError = fh
        }
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        try? p.run()
    }

    // MARK: Search (open sessions first, then older ones)
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var results: [SessionItem] = []
    private var searchWork: DispatchWorkItem?

    private func scheduleSearch() {
        searchWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { results = []; return }
        let work = DispatchWorkItem { [weak self] in self?.runSearch(q) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func runSearch(_ q: String) {
        var comps = URLComponents(url: base.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comps.url else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            struct R: Decodable { let s: [SessionItem] }
            let r = data.flatMap { try? JSONDecoder().decode(R.self, from: $0) }
            Task { @MainActor in
                if self.query.trimmingCharacters(in: .whitespaces) == q { self.results = r?.s ?? [] }
            }
        }.resume()
    }

    /// Close windows that hold one plain shell nobody used, when other session windows exist.
    static func closeUntouched(_ windows: [NSWindow]) {
        let all = NSApp.windows.filter { $0.windowController is BaseTerminalController && $0.isVisible }
        guard all.contains(where: { w in !windows.contains(where: { $0 === w }) }) else { return }
        for w in windows {
            guard let controller = w.windowController as? BaseTerminalController,
                  (w.tabGroup?.windows.count ?? 1) <= 1,
                  let leaves = controller.surfaceTree.root?.leaves(), leaves.count == 1,
                  let view = leaves.first, !view.needsConfirmQuit else { continue }
            controller.closeSurface(view, withConfirmation: false)
        }
    }

    func send(_ op: [String: Any], then: (@MainActor (Bool) -> Void)? = nil) {
        var req = URLRequest(url: base.appendingPathComponent("api/op"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: op)
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { data, _, error in
            // Never fail silently: show why an action did not happen.
            let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = (reply?["ok"] as? Bool) ?? (error == nil)
            let message = reply?["message"] as? String ?? error?.localizedDescription ?? "The session helper did not answer."
            if let then { Task { @MainActor in then(ok) } }
            guard !ok else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "That did not work"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }.resume()
    }

    func open(_ s: SessionItem) {
        if !query.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.query = "" }
        }
        if s.isOpen, s.be == "ghostty", let sf = s.sf,
           let view = SessionsAPI.allSurfaces().first(where: { $0.id.uuidString == sf }) {
            picked = s.k
            SessionsAPI.focus(view)
            return
        }
        if s.isOpen {
            // Running somewhere else (cmux): bring it here. Its old process ends, the
            // conversation resumes here with the same login.
            picked = s.k
            send(["op": "move", "k": s.k])
            return
        }
        // Closed or parked: resume it here.
        picked = s.k
        send(["op": "open", "k": s.k])
    }

    /// Go to the previous (-1) or next (+1) session that is open here, in the
    /// left column's order.
    func step(_ delta: Int) {
        guard let all = payload?.s else { return }
        let byKey = Dictionary(all.map { ($0.k, $0) }, uniquingKeysWith: { a, _ in a })
        let order = (navOrder.isEmpty ? all.map(\.k) : navOrder)
            .compactMap { byKey[$0] }
            .filter { $0.isOpen && $0.be == "ghostty" }
        guard !order.isEmpty else { return }
        let current = order.firstIndex(where: { $0.sf == focusedSurfaceID }) ?? (delta > 0 ? -1 : order.count)
        let next = (current + delta + order.count) % order.count
        open(order[next])
    }

    /// Ask what to do with a session that runs in cmux: move it here, or go to it there.
    func askMove(_ s: SessionItem) {
        let alert = NSAlert()
        alert.messageText = "“\(s.n)” is open in cmux"
        alert.informativeText = "Move it here closes it in cmux, with the shell split in that workspace, and resumes the same conversation here with the login you pick below.\n\nGo to it in cmux leaves it where it is."
        // Login to resume with; starts on the one it runs with now.
        let dirs = ["~/.claude", "~/.claude-ccl", "~/.claude-ccm"]
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for d in dirs {
            let name = payload?.spares?[d]?.lg ?? d
            popup.addItem(withTitle: "Login: " + name + (s.ld == d ? "  (now)" : ""))
        }
        popup.selectItem(at: dirs.firstIndex(of: s.ld ?? "~/.claude") ?? 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move it here")
        alert.addButton(withTitle: "Go to it in cmux")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn:
                self.picked = s.k
                self.send(["op": "move", "k": s.k, "login": dirs[max(0, popup.indexOfSelectedItem)]])
            case .alertSecondButtonReturn:
                self.send(["op": "open", "k": s.k])
            default:
                break
            }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func isSelected(_ s: SessionItem) -> Bool {
        if let p = picked { return p == s.k }
        guard let f = focusedSurfaceID else { return false }
        return s.isOpen && s.sf == f
    }
}

extension Notification.Name {
    static let sessionsFocusSearch = Notification.Name("sessions.focusSearch")
}

// MARK: - Looks

private struct Look {
    let icon: String
    let word: String
    let color: Color
}

private let orange = Color(red: 0.95, green: 0.63, blue: 0.36)
private let blue = Color(red: 0.50, green: 0.64, blue: 1.0)
private let green = Color(red: 0.36, green: 0.79, blue: 0.56)
private let grey = Color(white: 0.6)
private let selectedBlue = Color(red: 0.23, green: 0.36, blue: 0.86)

private func look(_ state: String) -> Look {
    switch state {
    case "urgent": return Look(icon: "exclamationmark.triangle.fill", word: "Urgent", color: Color(red: 0.95, green: 0.55, blue: 0.29))
    case "permission": return Look(icon: "hand.raised.fill", word: "Approve", color: orange)
    case "question": return Look(icon: "questionmark.circle", word: "Answer", color: orange)
    case "review": return Look(icon: "eye", word: "Look at it", color: orange)
    case "heads_up": return Look(icon: "exclamationmark.triangle", word: "Read this", color: orange)
    case "working": return Look(icon: "arrow.triangle.2.circlepath", word: "Working", color: blue)
    case "reading": return Look(icon: "ellipsis.circle", word: "Reading", color: grey)
    case "done": return Look(icon: "checkmark.circle", word: "Done", color: green)
    case "handled": return Look(icon: "checkmark.circle.fill", word: "Handled", color: green)
    case "parked": return Look(icon: "pause.circle", word: "Parked", color: grey)
    case "closed": return Look(icon: "moon", word: "Closed", color: grey)
    default: return Look(icon: "checkmark", word: "Answered", color: grey)
    }
}

private let needsStates: Set<String> = ["permission", "question", "review", "heads_up", "wrong_login"]

private func state(_ s: SessionItem) -> String {
    let st = s.st ?? "info"
    if (s.u ?? false) && needsStates.contains(st) { return "urgent" }
    return st
}

private func needsYou(_ s: SessionItem) -> Bool {
    let st = state(s)
    return st == "urgent" || needsStates.contains(st)
}

private func loginIcon(_ lg: String) -> String {
    switch lg {
    case "simplero.com": return "briefcase.fill"
    case "corre.li": return "person.fill"
    case "correli.me": return "star.fill"
    default: return "person"
    }
}

private func ago(_ t: Int?, now: Int) -> String {
    guard let t, t > 0 else { return "" }
    let d = max(0, now - t)
    if d < 60 { return "now" }
    if d < 3600 { return "\(d / 60)m" }
    if d < 86400 { return "\(d / 3600)h" }
    return "\(d / 86400)d"
}

// MARK: - One column

private enum Row: Identifiable {
    case header(String, Int)
    case session(SessionItem)
    case empty(String)

    var id: String {
        switch self {
        case .header(let n, _): return "h:" + n
        case .session(let s): return "s:" + s.k
        case .empty(let t): return "e:" + t
        }
    }
}

struct SessionsColumn: View {
    @ObservedObject var store: SessionsStore
    let key: String

    @AppStorage private var filter: String
    @AppStorage private var groupBy: String
    @AppStorage private var sortBy: String
    @State private var folded: Set<String> = ["Parked", "Closed recently"]

    init(store: SessionsStore, key: String, filter: String, groupBy: String, sortBy: String) {
        self.store = store
        self.key = key
        _filter = AppStorage(wrappedValue: filter, "sessions.\(key).filter")
        _groupBy = AppStorage(wrappedValue: groupBy, "sessions.\(key).group")
        _sortBy = AppStorage(wrappedValue: sortBy, "sessions.\(key).sort")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows()) { row in
                        switch row {
                        case .header(let name, let n):
                            header(name, n)
                        case .session(let s):
                            SessionRowView(store: store, s: s)
                        case .empty(let text):
                            Text(text).font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Filter, grouping and sort for this column.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                chip("Needs you", "needs", count { needsYou($0) })
                chip("Busy", "working", count { state($0) == "working" })
                chip("All", "all", count { _ in true })
                Spacer(minLength: 0)
            }
            HStack(spacing: 1) {
                pill("Flat", $groupBy, "none")
                pill("Class", $groupBy, "class")
                pill("Login", $groupBy, "login")
                pill("Dir", $groupBy, "folder")
                pill("Group", $groupBy, "cmux")
                Spacer(minLength: 0)
            }
            HStack(spacing: 1) {
                Text("Sort").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.trailing, 2)
                pill("Needs", $sortBy, "needs")
                pill("Visited", $sortBy, "recent")
                pill("Active", $sortBy, "active")
                pill("Manual", $sortBy, "manual")
                pill("A–Z", $sortBy, "name")
                Spacer(minLength: 0)
            }
        }
    }

    private func count(_ pred: (SessionItem) -> Bool) -> Int {
        (store.payload?.s ?? []).filter { $0.isOpen && pred($0) }.count
    }

    private func chip(_ label: String, _ value: String, _ n: Int) -> some View {
        Button { filter = value } label: {
            Text("\(label) \(n)")
                .font(.system(size: 11, weight: filter == value ? .semibold : .regular))
                .foregroundStyle(filter == value ? Color.white : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(filter == value ? selectedBlue : Color.gray.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func pill(_ label: String, _ binding: Binding<String>, _ value: String) -> some View {
        Button { binding.wrappedValue = value } label: {
            Text(label)
                .font(.system(size: 10.5, weight: binding.wrappedValue == value ? .semibold : .regular))
                .foregroundStyle(binding.wrappedValue == value ? Color.primary : Color.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(binding.wrappedValue == value ? Color.gray.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func header(_ name: String, _ n: Int) -> some View {
        Button {
            if folded.contains(name) { folded.remove(name) } else { folded.insert(name) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(folded.contains(name) ? 0 : 90))
                    .foregroundStyle(.tertiary)
                Text(name.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).lineLimit(1)
                Text("\(n)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Build this column's rows from the helper's data.
    private func rows() -> [Row] {
        let built = buildRows()
        if key == "col1" {
            let keys = built.compactMap { if case .session(let s) = $0 { return s.k } else { return nil } }
            if keys != store.navOrder { DispatchQueue.main.async { store.navOrder = keys } }
        }
        return built
    }

    private func buildRows() -> [Row] {
        guard let p = store.payload else {
            return [.empty(store.helperUp ? "Loading…" : "Starting the session helper…")]
        }
        let all = p.s
        let open = all.filter { $0.isOpen }
        let shown = open.filter { s in
            switch filter {
            case "needs": return needsYou(s)
            case "working": return state(s) == "working"
            default: return true
            }
        }
        var groupOfWs: [String: String] = [:]
        for g in p.grp ?? [] { for m in g.members ?? [] { groupOfWs[m] = g.name ?? "" } }
        let classOrder = p.classes ?? []

        func rank(_ s: SessionItem) -> Int {
            let st = state(s)
            if st == "urgent" { return 0 }
            if needsStates.contains(st) { return 1 }
            if st == "working" { return 2 }
            return 3
        }
        func order(_ a: SessionItem, _ b: SessionItem) -> Bool {
            switch sortBy {
            case "recent":
                let va = store.visits[a.k] ?? 0, vb = store.visits[b.k] ?? 0
                return va != vb ? va > vb : (a.la ?? 0) > (b.la ?? 0)
            case "active": return (a.la ?? 0) > (b.la ?? 0)
            case "name": return a.n.localizedCaseInsensitiveCompare(b.n) == .orderedAscending
            case "manual": return a.n.localizedCaseInsensitiveCompare(b.n) == .orderedAscending
            default:
                let ra = rank(a), rb = rank(b)
                return ra != rb ? ra < rb : (a.la ?? 0) > (b.la ?? 0)
            }
        }
        func groupKey(_ s: SessionItem) -> String {
            switch groupBy {
            case "login": return s.login
            case "folder": return (s.rm.map { $0 + ":" } ?? "") + (s.cwd ?? "~")
            case "cmux": return s.ws.flatMap { groupOfWs[$0] } ?? "No group"
            default: return s.c ?? "Work"
            }
        }

        var out: [Row] = []
        if filter != "all" {
            let here = open.filter { store.isSelected($0) && !shown.contains($0) }
            if !here.isEmpty {
                out.append(.header("You are here", here.count))
                out += here.map { .session($0) }
            }
        }
        if groupBy == "none" {
            out += shown.sorted(by: order).map { .session($0) }
        } else {
            var groups: [String: [SessionItem]] = [:]
            for s in shown { groups[groupKey(s), default: []].append(s) }
            let names = groups.keys.sorted { a, b in
                let ia = classOrder.firstIndex(of: a) ?? 99, ib = classOrder.firstIndex(of: b) ?? 99
                return ia != ib ? ia < ib : a < b
            }
            for name in names {
                let list = groups[name]!.sorted(by: order)
                out.append(.header(name, list.count))
                if !folded.contains(name) { out += list.map { .session($0) } }
            }
        }
        if shown.isEmpty {
            out.append(.empty(filter == "needs" ? "Nothing needs you right now." : "Nothing here."))
        }
        if filter != "all" {
            let inList = Set(shown.map(\.k))
            let recent = open.filter { !inList.contains($0.k) && !store.isSelected($0) }
                .sorted { (store.visits[$0.k] ?? Double($0.la ?? 0) / 1e6) > (store.visits[$1.k] ?? Double($1.la ?? 0) / 1e6) }.prefix(6)
            if !recent.isEmpty {
                out.append(.header("Recent", recent.count))
                if !folded.contains("Recent") { out += recent.map { .session($0) } }
            }
        }
        let parked = all.filter { $0.isParked && !$0.isOpen }
        if !parked.isEmpty {
            out.append(.header("Parked", parked.count))
            if !folded.contains("Parked") { out += parked.sorted { ($0.la ?? 0) > ($1.la ?? 0) }.map { .session($0) } }
        }
        let closed = all.filter { !$0.isOpen && !$0.isParked }.sorted { ($0.ca ?? 0) > ($1.ca ?? 0) }.prefix(40)
        if !closed.isEmpty {
            out.append(.header("Closed recently", closed.count))
            if !folded.contains("Closed recently") { out += closed.map { .session($0) } }
        }
        return out
    }
}

// MARK: - One session row

struct SessionRowView: View {
    @ObservedObject var store: SessionsStore
    let s: SessionItem
    @State private var hovering = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var addingLabel = false
    @State private var newLabel = ""

    var body: some View {
        if s.isOpen { runningRow } else { olderRow }
    }

    /// A session that is not running: small and grey, one line, no login.
    private var olderRow: some View {
        let lk = look(state(s))
        let title = (s.t?.isEmpty == false ? s.t : s.ns) ?? ""
        return HStack(spacing: 5) {
            Image(systemName: lk.icon).font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 14)
            Text(s.n).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if !title.isEmpty {
                Text(title).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(ago(s.ca ?? s.la, now: store.now)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.gray.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(s) }
        .help("Not running. Click to reopen it here.")
        .contextMenu { menu }
    }

    private var runningRow: some View {
        let st = state(s)
        let lk = look(st)
        let sel = store.isSelected(s)
        let line = (s.ns?.isEmpty == false ? s.ns : s.t) ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: lk.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(sel ? Color.white : lk.color)
                    .frame(width: 14)
                Text(s.n).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(sel ? Color.white : Color.primary)
                Spacer(minLength: 2)
                if hovering && needsYou(s) {
                    Button { store.send(["op": "ack", "k": s.k]) } label: {
                        Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(green)
                    }
                    .buttonStyle(.plain)
                    .help("Mark as handled. It comes back when the agent writes something new.")
                } else {
                    Text(ago(s.isOpen ? s.la : (s.ca ?? s.la), now: store.now))
                        .font(.system(size: 10)).foregroundStyle(sel ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Text(lk.word + (line.isEmpty ? "" : " · " + line))
                .font(.system(size: 11))
                .foregroundStyle(sel ? Color.white.opacity(0.9) : Color.secondary)
                .lineLimit(2)
                .padding(.leading, 19)
            HStack(spacing: 5) {
                HStack(spacing: 3) {
                    Image(systemName: loginIcon(s.login)).font(.system(size: 8))
                    Text(s.login + ((s.a ?? "claude") != "claude" ? " · " + (s.a ?? "") : ""))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(sel ? Color.white : Color.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(sel ? Color.white.opacity(0.2) : Color.gray.opacity(0.18)))
                if !s.labels.isEmpty {
                    Text(s.labels.map { "#" + $0 }.joined(separator: " ")).font(.system(size: 10)).foregroundStyle(blue).lineLimit(1)
                }
                if s.be == "cmux" {
                    Text("cmux").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.leading, 19)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(sel ? selectedBlue : (hovering ? Color.gray.opacity(0.14) : .clear)))
        .opacity(s.isOpen ? 1 : 0.75)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(s) }
        .contextMenu { menu }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if !newName.isEmpty { store.send(["op": "rename", "k": s.k, "name": newName]) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New label", isPresented: $addingLabel) {
            TextField("e.g. later", text: $newLabel)
            Button("Add") { if !newLabel.isEmpty { store.send(["op": "label", "k": s.k, "label": newLabel]) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var menu: some View {
        Button(s.isOpen ? "Go to session" : "Reopen here") { store.open(s) }
        if s.isOpen && s.be != "ghostty" {
            Button("Move it here from cmux…") { store.askMove(s) }
        }
        if s.isOpen {
            Button("Park (close it, keep it here)") { store.send(["op": "park", "k": s.k]) }
            Button("Close") { store.send(["op": "close", "k": s.k]) }
        } else if s.isParked {
            Button("Unpark") { store.send(["op": "unpark", "k": s.k]) }
        }
        Button(state(s) == "handled" ? "Needs me again" : "Mark as handled") { store.send(["op": "ack", "k": s.k]) }
        Divider()
        Menu("Class") {
            ForEach(store.payload?.classes ?? [], id: \.self) { c in
                Button((s.c == c ? "✓ " : "") + c) { store.send(["op": "cls", "k": s.k, "cls": c]) }
            }
        }
        Menu("Labels") {
            ForEach(store.payload?.labels ?? [], id: \.self) { l in
                Button((s.labels.contains(l) ? "✓ " : "") + l) { store.send(["op": "label", "k": s.k, "label": l]) }
            }
            Divider()
            Button("New label…") { newLabel = ""; addingLabel = true }
        }
        Button("Rename…") { newName = s.n; renaming = true }
        if let replies = s.rp, !replies.isEmpty, s.isOpen {
            Menu("Reply") {
                ForEach(Array(replies.enumerated()), id: \.offset) { _, r in
                    if r.count >= 2 { Button(r[0]) { store.send(["op": "send", "k": s.k, "text": r[1]]) } }
                }
            }
        }
        if let arts = s.art, !arts.isEmpty {
            Menu("Artifacts") {
                ForEach(arts, id: \.self) { u in
                    Button("Open " + (u.split(separator: "/").last.map(String.init) ?? u)) {
                        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        Menu("Switch login") {
            ForEach(["~/.claude", "~/.claude-ccl", "~/.claude-ccm"], id: \.self) { d in
                let name = store.payload?.spares?[d]?.lg ?? d
                Button((s.ld == d ? "✓ " : "") + name) {
                    if s.ld != d { store.send(["op": "switch", "k": s.k, "login": d]) }
                }
            }
        }
        Divider()
        if !s.isOpen {
            Button("Remove from list", role: .destructive) { store.send(["op": "forget", "k": s.k]) }
        }
    }
}

// MARK: - The whole sidebar

struct SessionsSidebar: View {
    @ObservedObject var store = SessionsStore.shared
    @Binding var visible: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "bolt").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("NEW CLAUDE").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                ForEach(["~/.claude", "~/.claude-ccl", "~/.claude-ccm"], id: \.self) { d in
                    Button {
                        store.send(["op": "new", "login": d])
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(green)
                            Text(store.payload?.spares?[d]?.lg ?? d).font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help("New Claude session with this login")
                }
                Spacer()
                Button { visible = false } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide the sessions sidebar")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search sessions (⌘P): name, next step, label, login, folder…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit {
                        // Enter opens the first match.
                        if let first = store.results.first { store.query = ""; store.open(first) }
                    }
                    .onExitCommand { store.query = ""; searchFocused = false }
                if !store.query.isEmpty {
                    Button { store.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.14)))
            if !store.helperUp {
                Label("The session helper is not answering.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(orange)
            }
            if store.query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    SessionsColumn(store: store, key: "col1", filter: "needs", groupBy: "none", sortBy: "needs")
                    Divider()
                    SessionsColumn(store: store, key: "col2", filter: "all", groupBy: "cmux", sortBy: "manual")
                }
            } else {
                SearchResults(store: store)
            }
        }
        .padding(.horizontal, 8).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { store.start() }
        .onReceive(NotificationCenter.default.publisher(for: .sessionsFocusSearch)) { _ in
            if !visible { visible = true }
            searchFocused = true
        }
    }
}

/// Wraps a terminal window's content with the sessions sidebar on the left.
struct SessionsSidebarContainer<Content: View>: View {
    @AppStorage("sessions.sidebar.visible") private var visible = true
    /// Web sidebar (served by the helper, reloads without an app restart) or the native one.
    @AppStorage("sessions.sidebar.web") private var web = true
    @AppStorage("sessions.sidebar.width") private var width: Double = 460
    @State private var dragStart: Double?
    let surfaceIDs: [String]
    let content: Content

    init(surfaceIDs: [String] = [], @ViewBuilder content: () -> Content) {
        self.surfaceIDs = surfaceIDs
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if visible {
                Group {
                    if web {
                        ZStack(alignment: .topTrailing) {
                            SessionsWebSidebar()
                            Button { visible = false } label: {
                                Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(.secondary)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .help("Hide the sessions sidebar")
                        }
                    } else {
                        SessionsSidebar(visible: $visible)
                    }
                }
                    .frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor))
                Rectangle()
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: 1)
                    .overlay(
                        Color.clear.frame(width: 7).contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { v in
                                    if dragStart == nil { dragStart = width }
                                    width = min(1000, max(300, (dragStart ?? width) + v.translation.width))
                                }
                                .onEnded { _ in dragStart = nil })
                    )
            } else {
                Button { visible = true } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 22).frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
                }
                .buttonStyle(.plain)
                .help("Show the sessions sidebar")
            }
            VStack(spacing: 0) {
                if web {
                    WebBanner()
                } else {
                    UpdateBanner()
                    SessionBanner(surfaceIDs: surfaceIDs)
                }
                content
            }
        }
    }
}

/// Above the terminal, when a newer build is installed.
struct UpdateBanner: View {
    @ObservedObject var version = SessionsVersion.shared

    var body: some View {
        if version.updateAvailable {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
                Text("A newer Switchboard is installed: b\(version.installedBuild). You run b\(version.runningBuild).")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Restart to update") { version.restart() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selectedBlue)
        }
    }
}

/// Above the terminal: which session this is, its login, when it last did
/// something, what it needs from you, and the last thing that happened.
struct SessionBanner: View {
    @ObservedObject var store = SessionsStore.shared
    let surfaceIDs: [String]

    var body: some View {
        let s = store.payload?.s.first(where: { $0.isOpen && $0.sf.map(surfaceIDs.contains) == true })
        if let s {
            let st = state(s)
            let lk = look(st)
            let needs = needsYou(s)
            let step: String = st == "working" ? (s.wl?.isEmpty == false ? s.wl! : "Working…") : (s.ns?.isEmpty == false ? s.ns! : "Nothing needs you here.")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.n).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: lk.icon).font(.system(size: 10, weight: .semibold))
                        Text(lk.word).font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(lk.color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(lk.color.opacity(0.15)))
                    HStack(spacing: 3) {
                        Image(systemName: loginIcon(s.login)).font(.system(size: 9))
                        Text(s.login).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.18)))
                    Text("updated \(ago(s.la, now: store.now)) ago".replacingOccurrences(of: "now ago", with: "just now"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(needs ? "Needs you:" : "Next:").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(needs ? lk.color : .secondary)
                    Text(step).font(.system(size: 12, weight: needs ? .semibold : .regular)).lineLimit(2)
                }
                if let said = s.sd, !said.isEmpty, st != "working" {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Last:").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        Text(said).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Rectangle().fill(needs ? lk.color : Color.gray.opacity(0.25)).frame(height: needs ? 2 : 1), alignment: .bottom)
        }
    }
}


/// Search results across both columns: sessions that are open now first, then older ones.
struct SearchResults: View {
    @ObservedObject var store: SessionsStore

    var body: some View {
        let open = store.results.filter { $0.isOpen }
        let older = store.results.filter { !$0.isOpen }
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                if store.results.isEmpty {
                    Text("No session matches “\(store.query)”.").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                }
                if !open.isEmpty {
                    Text("OPEN NOW · \(open.count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(open) { SessionRowView(store: store, s: $0) }
                }
                if !older.isEmpty {
                    Text("OLDER · \(older.count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).padding(.top, 10)
                    ForEach(older) { SessionRowView(store: store, s: $0) }
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


/// The banner above the terminal as a web page (http://127.0.0.1:4477/banner).
struct WebBanner: View {
    @ObservedObject var page = SessionsWeb.banner

    var body: some View {
        SessionsWebSidebar(page: page)
            .frame(height: SessionsWeb.bannerHeight)
    }
}
