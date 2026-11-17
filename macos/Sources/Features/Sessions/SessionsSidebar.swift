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

    var id: String { k }
    var isOpen: Bool { o ?? false }
    var isParked: Bool { pk ?? false }
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
    private var startedHelper = false
    private let base = URL(string: "http://127.0.0.1:4477")!

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshFocus() }
        }
        tick()
    }

    func refreshFocus() {
        let controller = NSApp.keyWindow?.windowController as? BaseTerminalController
        let id = controller?.focusedSurface?.id.uuidString
        if id != focusedSurfaceID { focusedSurfaceID = id }
        if let p = picked, let s = payload?.s.first(where: { $0.k == p }), s.sf == id { picked = nil }
    }

    private func tick() {
        now = Int(Date().timeIntervalSince1970)
        refreshFocus()
        var req = URLRequest(url: base.appendingPathComponent("api/sidebar"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, error in
            let decoded = data.flatMap { try? JSONDecoder().decode(SidebarPayload.self, from: $0) }
            Task { @MainActor in
                if let decoded {
                    if decoded != self.payload { self.payload = decoded }
                    self.helperUp = true
                } else {
                    self.helperUp = false
                    if error != nil { self.startHelperIfNeeded() }
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

    func send(_ op: [String: Any]) {
        var req = URLRequest(url: base.appendingPathComponent("api/op"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: op)
        URLSession.shared.dataTask(with: req).resume()
    }

    func open(_ s: SessionItem) {
        picked = s.k
        if s.isOpen, s.be == "ghostty", let sf = s.sf,
           let view = SessionsAPI.allSurfaces().first(where: { $0.id.uuidString == sf }) {
            SessionsAPI.focus(view)
            return
        }
        send(["op": "open", "k": s.k])
    }

    func isSelected(_ s: SessionItem) -> Bool {
        if let p = picked { return p == s.k }
        guard let f = focusedSurfaceID else { return false }
        return s.isOpen && s.sf == f
    }
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
    case "work": return "briefcase.fill"
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
                pill("Recent", $sortBy, "recent")
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
            case "recent": return (a.la ?? 0) > (b.la ?? 0)
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
                .sorted { ($0.la ?? 0) > ($1.la ?? 0) }.prefix(6)
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
        let st = state(s)
        let lk = look(st)
        let sel = store.isSelected(s)
        let line = (s.ns?.isEmpty == false ? s.ns : s.t) ?? ""
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: lk.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(sel ? Color.white : lk.color)
                    .frame(width: 14)
                Text(s.n).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
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
        Button(s.isOpen ? "Go to session" : "Reopen") { store.open(s) }
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
            if !store.helperUp {
                Label("The session helper is not answering.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(orange)
            }
            HStack(alignment: .top, spacing: 10) {
                SessionsColumn(store: store, key: "col1", filter: "needs", groupBy: "none", sortBy: "needs")
                Divider()
                SessionsColumn(store: store, key: "col2", filter: "all", groupBy: "cmux", sortBy: "manual")
            }
        }
        .padding(.horizontal, 8).padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { store.start() }
    }
}

/// Wraps a terminal window's content with the sessions sidebar on the left.
struct SessionsSidebarContainer<Content: View>: View {
    @AppStorage("sessions.sidebar.visible") private var visible = true
    @AppStorage("sessions.sidebar.width") private var width: Double = 460
    @State private var dragStart: Double?
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if visible {
                SessionsSidebar(visible: $visible)
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
            content
        }
    }
}
