import AppKit
import SwiftUI

// The sessions sidebar: every coding-agent session (open or closed). The data comes
// from the session tracker in this app (Switchboard); the sidebar and the panel are
// web pages (SessionsWebSidebar.swift). This file has the native side: the data the
// menus use, keyboard shortcuts, focus, and actions.

// MARK: - Data from the tracker

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
    /// The key this session had before its conversation id arrived.
    let was: String?
    /// Pinned: its place in the Pinned row (0 first).
    let pn: Int?
    /// A pinned shell's command (lazygit).
    let pc: String?
    /// The folder it moves to when its turn is over (Move to folder).
    let mv: String?
    /// The other machine it runs on; nil: this Mac.
    let m: String?
    /// `mv` is a machine (it moves there with its work tree), not a folder.
    let mvm: Bool?

    var id: String { k }
    var isOpen: Bool { o ?? false }
    var isParked: Bool { pk ?? false }
    var isArchived: Bool { ar ?? false }
    var labels: [String] { lb ?? [] }
    var login: String { lg ?? "" }
    var isPinned: Bool { pn != nil }
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

    @Published var payload: SidebarPayload? {
        didSet { if let p = payload { SessionHistory.shared.remap(p.s) } }
    }
    @Published var focusedSurfaceID: String?
    @Published var now = Int(Date().timeIntervalSince1970)
    /// A clicked row highlights at once; cleared when focus catches up.
    @Published var picked: String?

    private var timer: Timer?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// The left column's session order, for ⌘↑ / ⌘↓.
    var navOrder: [String] = []

    func start() {
        guard timer == nil else { return }
        Switchboard.shared.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        SessionsAPI.trackActiveTabs()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { SessionSwitchLog.noteEvent() }
            Task { @MainActor in self?.refreshFocus() }
        }
        // Away in another app: the sidebar notes whether its rows move meanwhile (a click that
        // brings Switchboard back then lands on another row than the one you saw).
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionsWebView.listMovedWhileAway = false
                SessionsWeb.shared.webView.evaluateJavaScript("window.Sessions && Sessions.away && Sessions.away(true)")
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionSwitchLog.activeSince = Date()
                SessionSwitchLog.noteEvent("back from another app by ")
                SessionsWeb.shared.webView.evaluateJavaScript("window.Sessions && Sessions.away && Sessions.away(false)")
            }
        }
        // ⌘↑ / ⌘↓: previous / next session.  ⌘P: search.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // The new-session form is open and has the keyboard: every key is for the form
            // (⌘↑ ⌘↓ ⌘← ⌘→ move in the text), none switches sessions.
            let page = SessionsWeb.shared.webView
            if SessionsWebView.newFormOpen, let r = page.window?.firstResponder as? NSView,
               r === page || r.isDescendant(of: page) {
                return event
            }
            // A page in the pane has the keyboard: ⌘ arrows move in it, not between sessions.
            if (123...126).contains(event.keyCode), let r = NSApp.keyWindow?.firstResponder as? NSView,
               r is DocWebView || r.enclosingDocWebView != nil {
                return event
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // ⌃1…⌃9: the pins. The same key again goes back to the session you were in.
            if mods == .control, !event.isARepeat, let c = event.charactersIgnoringModifiers, c.count == 1,
               let n = Int(c), (1...9).contains(n), n <= self.pins.count {
                self.openPin(n)
                return nil
            }
            if mods == .command {
                // Arrows by key code (the same on every layout). Letters by the
                // character the layout types: key code 35 is P only on QWERTY
                // (on Dvorak it is L, and Dvorak P is key code 15).
                if event.keyCode == 126 { self.step(-1); return nil }   // up arrow
                if event.keyCode == 125 { self.step(1); return nil }    // down arrow
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "[":
                    // ⌘[ ⌘]: back and forward between sessions, like a browser.
                    SessionHistory.shared.goBack("⌘[ (back)")
                    return nil
                case "]":
                    SessionHistory.shared.goForward("⌘] (forward)")
                    return nil
                case "p":
                    UserDefaults.standard.set(true, forKey: "sessions.sidebar.visible")
                    SessionsWeb.shared.focusSearch()
                    return nil
                case "n":
                    // ⌘N: a new session with a plain shell (no agent), not a bare window.
                    // Holding the keys down must not open a row of them.
                    if !event.isARepeat { self.newShellSession() }
                    return nil
                case let c? where c.count == 1 && "123456789".contains(c):
                    // ⌘1…⌘9: tabs of this session only (macOS would count every session's
                    // tabs, since they are all tabs of the one window). ⌘9 is the last one.
                    guard let controller = NSApp.keyWindow?.windowController as? TerminalController else { break }
                    SessionsAPI.gotoSessionTab(Int(c) ?? 1, from: controller)
                    return nil
                default: break
                }
            }
            return event
        }
        // The mouse's back and forward buttons (button 4 and 5) go back and forward too.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: SessionHistory.shared.goBack("the mouse's back button"); return nil
            case 4: SessionHistory.shared.goForward("the mouse's forward button"); return nil
            default: return event
            }
        }
        tick()
    }

    /// Before Done / Close / Park: if something other than the agent still runs in the
    /// session (a server in a shell tab, an editor), ask first. The agent's conversation
    /// is saved, so it does not need asking. Returns true to go ahead.
    func confirmClose(_ k: String, action: String) -> Bool {
        guard let s = payload?.s.first(where: { $0.k == k }), s.isOpen, let sf = s.sf,
              let view = SessionsAPI.surface(id: sf),
              let controller = BaseTerminalController.controller(owning: view) as? TerminalController else { return true }
        // The agent's own terminal needs no asking, but only while the agent still runs in it
        // (after it exits, the same terminal may run an editor or a server).
        let agentRuns = s.a != "shell" && (Switchboard.shared.entry(k)?.pid).map(SBProcesses.isAlive) == true
        let busy = SessionsAPI.windows(ofWorkspace: controller.sessionsWorkspace)
            .compactMap { ($0.windowController as? BaseTerminalController)?.surfaceTree.root?.leaves() }
            .flatMap { $0 }
            .filter { ($0.id.uuidString != sf || !agentRuns) && $0.needsConfirmQuit }
        guard !busy.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "\(action) “\(s.n)”?"
        let names = busy.map { $0.title.isEmpty ? "a shell" : "“\($0.title)”" }.joined(separator: ", ")
        alert.informativeText = "Something still runs in this session: \(names). \(action) ends it."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The pinned sessions, in the order of the Pinned row.
    var pins: [SessionItem] {
        (payload?.s ?? []).filter(\.isPinned).sorted { ($0.pn ?? 0) < ($1.pn ?? 0) }
    }

    /// The session you were in before you went to a pin: the pin's key takes you back to it.
    private var pinReturn: String?

    /// ⌃n: open pin n. When it is in front already, go back to the session you came from.
    func openPin(_ n: Int) {
        let all = pins
        guard all.indices.contains(n - 1) else { return }
        let p = all[n - 1]
        let front = payload?.s.first { $0.isOpen && $0.sf != nil && $0.sf == focusedSurfaceID }
        if let front, front.k == p.k {
            if let r = pinReturn, r != p.k, payload?.s.first(where: { $0.k == r })?.isOpen == true {
                open(key: r, via: "⌃\(n) again (back from the pin “\(p.n)”)")
            } else {
                SessionHistory.shared.goBack("⌃\(n) again (back from the pin “\(p.n)”)")
            }
            return
        }
        open(key: p.k, via: "⌃\(n) (the pin “\(p.n)”)")
    }

    /// A new session with a plain shell, in the folder of the terminal you are in.
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

    /// A tab shows for a moment while it opens in the background (TerminalController.newTab):
    /// not a switch.
    static var quietUntil = Date.distantPast

    func refreshFocus() {
        guard Date() >= Self.quietUntil else { return }
        // In another app no window is key: the session in front is still the one the window
        // shows (it keeps its place in the list, and a switch meanwhile shows in the log).
        let shownWindow = NSApp.keyWindow ?? (NSApp.isActive ? nil : SessionsAPI.mainWindow().map { $0.tabGroup?.selectedWindow ?? $0 })
        let controller = shownWindow?.windowController as? BaseTerminalController
        var id = controller?.focusedSurface?.id.uuidString
        // In another tab of a session (a shell next to Claude) the session in front is still
        // that session: report its own terminal, so the sidebar keeps it selected.
        if let shown = id, payload?.s.contains(where: { $0.sf == shown && $0.isOpen }) != true,
           let tc = controller as? TerminalController {
            let ids = Set(SessionsAPI.windows(ofWorkspace: tc.sessionsWorkspace).flatMap {
                ($0.windowController as? BaseTerminalController)?.surfaceTree.root?.leaves().map { $0.id.uuidString } ?? []
            })
            if let s = payload?.s.first(where: { $0.isOpen && $0.sf.map { ids.contains($0) } == true }) { id = s.sf }
        }
        if id != focusedSurfaceID {
            let was = payload?.s.first { $0.isOpen && $0.sf != nil && $0.sf == focusedSurfaceID }
            if let was, !was.isPinned, let id, payload?.s.first(where: { $0.sf == id && $0.isOpen })?.isPinned == true { pinReturn = was.k }
            focusedSurfaceID = id
            SessionsWeb.shared.setFocus(id)
            SessionsWeb.banner.pushBannerContext()
            // Back and forward, like a browser.
            if let id, let s = payload?.s.first(where: { $0.sf == id && $0.isOpen }) {
                SessionHistory.shared.visited(s.k)
                SessionSwitchLog.front(s)
            }
        }
        recordVisit()
        if let p = picked, let s = payload?.s.first(where: { $0.k == p }), s.sf == id { picked = nil }
    }

    private func tick() {
        now = Int(Date().timeIntervalSince1970)
        refreshFocus()
        SessionsWeb.banner.pushBannerContext()
    }

    /// Close windows that hold one plain shell nobody used, when other session windows exist.
    static func closeUntouched(_ windows: [NSWindow]) {
        let all = NSApp.windows.filter { $0.windowController is BaseTerminalController && $0.isVisible }
        guard all.contains(where: { w in !windows.contains(where: { $0 === w }) }) else { return }
        for w in windows {
            guard let controller = w.windowController as? BaseTerminalController,
                  // Alone in its session (its own tab, nothing else of it).
                  SessionsAPI.windows(ofWorkspace: (controller as? TerminalController)?.sessionsWorkspace ?? "").count <= 1,
                  let leaves = controller.surfaceTree.root?.leaves(), leaves.count == 1,
                  let view = leaves.first, !view.needsConfirmQuit else { continue }
            controller.closeSurface(view, withConfirmation: false)
        }
    }

    /// Run an action. Never fails silently: when it does not work, say why.
    func send(_ op: [String: Any], then: (@MainActor (Bool) -> Void)? = nil) {
        Task { @MainActor in
            let (ok, message) = await Switchboard.shared.dispatch(op)
            then?(ok)
            if !ok { showFailure(message) }
        }
    }

    func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "That did not work"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func open(_ s: SessionItem) { open(key: s.k, name: s.n, surface: s.isOpen ? s.sf : nil) }

    /// Open a session by its key (a search result may not be in the sidebar's data).
    func open(key k: String, via: String? = nil) {
        if let via { SessionSwitchLog.because(via) }
        let e = Switchboard.shared.entry(k)
        open(key: k, name: e?.name ?? "This session", surface: e?.isOpen == true ? e?.surface_id : nil)
    }

    private func open(key k: String, name: String, surface sf: String?) {
        picked = k
        if let sf, let view = SessionsAPI.surface(id: sf) {
            SessionsAPI.focus(view)
            Switchboard.shared.startPinCommandIfIdle(k)
            return
        }
        // Closed, parked or archived: resume it here. A conversation that still runs in cmux
        // or another terminal would then run twice: ask first, and end it there.
        if Switchboard.shared.runningElsewhere(k) != nil {
            let alert = NSAlert()
            if Switchboard.shared.entry(k)?.backend == "claude-app" {
                alert.messageText = "“\(name)” runs in the Claude app"
                alert.informativeText = "Move here stops it in the Claude app and resumes the same conversation here. After that, continue it only here: if you type in it in the Claude app again, the conversation splits in two."
                alert.addButton(withTitle: "Move here")
            } else {
                alert.messageText = "“\(name)” still runs outside Switchboard"
                alert.informativeText = "It runs in cmux or another terminal. Reopen it here ends it there (its tab there stays, at a shell prompt) and resumes the same conversation here."
                alert.addButton(withTitle: "Reopen here")
            }
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { picked = nil; return }
            send(["op": "open", "k": k, "end_elsewhere": true])
            return
        }
        send(["op": "open", "k": k])
    }

    /// Go to the previous (-1) or next (+1) session that is open, in the order of the sidebar
    /// column you last opened a session from (the page sends it as `nav`).
    func step(_ delta: Int) {
        guard let all = payload?.s else { return }
        let byKey = Dictionary(all.map { ($0.k, $0) }, uniquingKeysWith: { a, _ in a })
        let order = (navOrder.isEmpty ? all.map(\.k) : navOrder)
            .compactMap { byKey[$0] }
            .filter { $0.isOpen && !$0.isPinned }
        guard !order.isEmpty else { return }
        let current = order.firstIndex(where: { $0.sf == focusedSurfaceID }) ?? (delta > 0 ? -1 : order.count)
        let next = (current + delta + order.count) % order.count
        SessionSwitchLog.because(delta > 0 ? "⌘↓ (next session)" : "⌘↑ (previous session)")
        open(order[next])
    }
}

/// Wraps a terminal window's content with the sessions sidebar on the left.
struct SessionsSidebarContainer<Content: View>: View {
    @AppStorage("sessions.sidebar.visible") private var visible = true
    @AppStorage("sessions.sidebar.width") private var width: Double = 460
    @AppStorage("sessions.docpane.width") private var paneWidth: Double = 560
    @State private var dragStart: Double?
    @State private var paneDragStart: Double?
    @ObservedObject private var panes = SessionsDocPanes.shared
    let surfaceIDs: [String]
    /// Off for the quick terminal: the sidebar and panel belong to the session window.
    let enabled: Bool
    let content: Content

    init(surfaceIDs: [String] = [], enabled: Bool = true, @ViewBuilder content: () -> Content) {
        self.surfaceIDs = surfaceIDs
        self.enabled = enabled
        self.content = content()
    }

    var body: some View {
        if enabled { withSidebar } else { content }
    }

    private var withSidebar: some View {
        GeometryReader { geo in layout(total: geo.size.width) }
    }

    /// The pane's width: what you dragged it to, but never so wide that the terminal gets
    /// less than 420 points (nor narrower than 320).
    private func paneShown(total: CGFloat) -> CGFloat {
        let left = visible ? CGFloat(width) + 7 : 22
        return max(320, min(CGFloat(paneWidth), total - left - 7 - 420))
    }

    private func layout(total: CGFloat) -> some View {
        HStack(spacing: 0) {
            if visible {
                ZStack(alignment: .topTrailing) {
                    SessionsWebSidebar()
                    Button { visible = false } label: {
                        Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Hide the sessions sidebar")
                }
                    .frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor))
                ResizeHandle { dx in
                    if dragStart == nil { dragStart = width }
                    width = min(1000, max(300, (dragStart ?? width) + dx))
                } ended: { dragStart = nil }
            } else {
                Button { visible = true } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 22).frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
                }
                .buttonStyle(.plain)
                .help("Show the sessions sidebar")
            }
            VStack(spacing: 0) {
                WebBanner()
                content
            }
            // A Doc opened from the panel: on the right, next to the session it belongs to.
            if let ws = sessionID, let page = panes.pages[ws] {
                ResizeHandle { dx in
                    // Start from the width on screen (it can be less than the saved one).
                    if paneDragStart == nil { paneDragStart = Double(paneShown(total: total)) }
                    paneWidth = min(1400, max(320, (paneDragStart ?? paneWidth) - dx))
                } ended: { paneDragStart = nil }
                DocPaneView(page: page) { panes.close(session: ws) }
                    .frame(width: paneShown(total: total))
            }
        }
    }

    /// The session this window belongs to.
    private var sessionID: String? {
        for id in surfaceIDs {
            if let view = SessionsAPI.surface(id: id),
               let controller = BaseTerminalController.controller(owning: view) as? TerminalController {
                return controller.sessionsWorkspace
            }
        }
        return nil
    }
}

/// A divider you drag: 7 points wide in the row itself (a 1-point line in the middle), so no
/// terminal or web view sits on top of it and takes the mouse.
struct ResizeHandle: View {
    let changed: (CGFloat) -> Void
    let ended: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color.gray.opacity(hovering ? 0.5 : 0.25)).frame(width: 1)
        }
        .frame(width: 7)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { changed($0.translation.width) }
            .onEnded { _ in ended() })
    }
}

/// The panel above the terminal (a web page shipped in the app).
struct WebBanner: View {
    @ObservedObject var page = SessionsWeb.banner

    var body: some View {
        SessionsWebSidebar(page: page)
            .frame(height: SessionsWeb.bannerHeight)
    }
}
