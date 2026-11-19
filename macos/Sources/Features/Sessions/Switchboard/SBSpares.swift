import AppKit
import GhosttyKit

/// Claude started ahead of time: one per login, in the folder new sessions start in, each in
/// a window that is never shown. A new session from the sidebar takes the spare of its login
/// (Claude already waits at its prompt), so it is there at once; a new spare starts behind it.
///
/// - A spare is not a session: the tracker, the tab list, the API and the handoff on update
///   skip it (`TerminalController.sessionsSpare`).
/// - It starts again when it is 30 minutes old, when the claude program on disk changes (an
///   update), or when you pick another folder: a new session gets the current Claude, its
///   settings, MCP servers and git status.
/// - SWITCHBOARD_NO_SPARES=1 turns spares off.
@MainActor
final class SBSpares {
    static let shared = SBSpares()

    final class Spare {
        let login: String
        let folder: String
        let controller: TerminalController
        let view: Ghostty.SurfaceView
        let started: Double
        /// The claude program it runs (see `claudeStamp`).
        let stamp: String?
        let restorable: Bool
        var readyAt: Double?
        /// Scans in a row that did not see Claude's prompt (a redraw can hide it for a moment).
        var misses = 0

        init(login: String, folder: String, controller: TerminalController, view: Ghostty.SurfaceView,
             started: Double, stamp: String?, restorable: Bool) {
            self.login = login
            self.folder = folder
            self.controller = controller
            self.view = view
            self.started = started
            self.stamp = stamp
            self.restorable = restorable
        }
    }

    private(set) var spares: [String: Spare] = [:]
    /// Where new sessions start: the sidebar's "New Claude in" folder (expanded).
    var folder = SBPaths.expand(Switchboard.defaultFolder)
    private var failedAt: [String: Double] = [:]
    private var firstTick: Double?
    private var nextStart: Double = 0
    private var lastRecycle: Double = 0
    private var stamp: String?
    private var stampAt: Double = 0
    private let enabled = ProcessInfo.processInfo.environment["SWITCHBOARD_NO_SPARES"] == nil

    /// SWITCHBOARD_SPARE_MAX_AGE (seconds) for checks.
    static let maxAge = Double(ProcessInfo.processInfo.environment["SWITCHBOARD_SPARE_MAX_AGE"] ?? "") ?? 30 * 60
    /// Claude not at its prompt by then (a dialog, an error): close it, try again later.
    static let readyWithin = 90.0
    static let retryAfter = 15.0 * 60

    private var now: Double { Date().timeIntervalSince1970 }

    /// Every scan: notice spares that became ready or ended, start missing ones, renew old ones.
    func tick() {
        guard enabled, Switchboard.shared.loaded else { return }
        let t = now
        if firstTick == nil { firstTick = t }
        if t - stampAt > 60 { stampAt = t; stamp = Self.claudeStamp() }
        // No session window left (you closed them all): no spares either, so the app has
        // no windows and the Dock icon opens a new one as usual.
        guard let main = SessionsAPI.mainWindow() else {
            for login in Array(spares.keys) { discard(login, failed: false) }
            return
        }
        for (login, s) in spares {
            guard let w = s.controller.window,
                  s.controller.surfaceTree.root?.leaves().contains(where: { $0 === s.view }) == true else {
                spares[login] = nil
                continue
            }
            // Another folder for new sessions: this spare is of no use any more.
            if s.folder != folder {
                discard(login, failed: false)
                continue
            }
            Self.fit(w, to: main)
            if Self.atPrompt(s.view) {
                if s.readyAt == nil { s.readyAt = t }
                s.misses = 0
            } else {
                s.misses += 1
                // Claude ended, or never got to its prompt.
                if s.readyAt != nil ? s.misses >= 3 : t - s.started > Self.readyWithin {
                    discard(login, failed: true)
                    continue
                }
            }
            // Old, or an older claude than the one on disk: renew it. One at a time, and only
            // a spare that got to its prompt (no endless restarts).
            let stale = (stamp != nil && s.stamp != stamp) || t - s.started > Self.maxAge
            if stale, s.readyAt != nil, t - lastRecycle > 20 {
                lastRecycle = t
                discard(login, failed: false)
            }
        }
        // Start missing spares one by one, after the app had 20 s to bring its sessions back.
        guard t - (firstTick ?? t) >= 20, t >= nextStart else { return }
        for login in SBLogins.dirs where spares[login] == nil && t - (failedAt[login] ?? 0) > Self.retryAfter {
            nextStart = t + 5
            start(login, main: main)
            break
        }
    }

    /// The spare of this login, when Claude waits at its prompt in this folder. The caller
    /// shows it as a new session.
    func take(_ login: String, folder: String) -> Spare? {
        guard let s = spares[login], s.folder == folder, s.readyAt != nil, Self.atPrompt(s.view) else { return nil }
        spares[login] = nil
        s.controller.sessionsSpare = false
        s.controller.window?.isExcludedFromWindowsMenu = false
        s.controller.window?.isRestorable = s.restorable
        // The next spare waits a bit, so its start does not compete with your first message.
        nextStart = max(nextStart, now + 15)
        return s
    }

    /// For the sidebar: which logins have a spare ready in the current folder.
    func info() -> [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: SBLogins.dirs.map { d in
            let s = spares[d]
            let ready = s?.readyAt != nil && s?.folder == folder
            return (d, ["lg": SBLogins.short(d), "ready": ready, "warming": s != nil && !ready] as [String: Any])
        })
    }

    /// For checks: each spare, with its terminal size and the end of its screen.
    func checkInfo() -> [[String: Any]] {
        spares.values.sorted { $0.login < $1.login }.map { s in
            let grid = SessionsAPI.gridSize(s.view)
            let text = SessionsAPI.activeText(of: s.view) ?? ""
            return ["login": s.login, "folder": s.folder, "ready": s.readyAt != nil, "age": Int(now - s.started),
                    "grid": grid.map { [$0.cols, $0.rows] } ?? [], "frame": s.controller.window.map { NSStringFromRect($0.frame) } ?? "",
                    "visible": s.controller.window?.isVisible ?? false,
                    "tail": text.split(separator: "\n").suffix(6).joined(separator: "\n")]
        }
    }

    /// The terminals of the spares: their Claude runs in this app, not "elsewhere".
    var ttys: [String] { spares.values.compactMap { $0.view.surfaceModel?.ttyName }.filter { !$0.isEmpty } }

    private func start(_ login: String, main: NSWindow) {
        guard let app = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        config.initialInput = Switchboard.claudeLaunch(login) + " --dangerously-skip-permissions\n"
        if login != "~/.claude" { config.environmentVariables = ["CLAUDE_CONFIG_DIR": SBPaths.expand(login)] }
        let c = TerminalController(app, withBaseConfig: config)
        c.sessionsSpare = true   // before the window exists: nothing may take it for a session
        guard let w = c.window, let view = c.surfaceTree.root?.leaves().first else {
            Self.close(c)
            failedAt[login] = now
            return
        }
        let restorable = w.isRestorable
        w.isRestorable = false
        w.isExcludedFromWindowsMenu = true
        if let mc = main.windowController as? TerminalController { c.isBackgroundOpaque = mc.isBackgroundOpaque }
        Self.fit(w, to: main)
        spares[login] = Spare(login: login, folder: folder, controller: c, view: view, started: now,
                              stamp: stamp, restorable: restorable)
    }

    private func discard(_ login: String, failed: Bool) {
        guard let s = spares.removeValue(forKey: login) else { return }
        if failed { failedAt[login] = now }
        Self.close(s.controller)
    }

    /// Close a window and end its program now (no Undo that keeps it alive).
    static func close(_ c: TerminalController) {
        SessionsAPI.withoutUndo(c) { c.closeWindowImmediately() }
    }

    /// The same size as the one window, so Claude draws at the width it will have.
    private static func fit(_ w: NSWindow, to main: NSWindow) {
        guard w.frame != main.frame else { return }
        w.setFrame(main.frame, display: false)
        w.contentView?.layoutSubtreeIfNeeded()
    }

    /// Claude waits at its prompt: its footer shows (every session starts with
    /// --dangerously-skip-permissions) and nothing works or asks.
    static func atPrompt(_ view: Ghostty.SurfaceView) -> Bool {
        guard let text = SessionsAPI.activeText(of: view) else { return false }
        let tail = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(8)
        return tail.contains { $0.contains("bypass permissions on") } && SBScreen.state(text) == "idle"
    }

    /// Which claude program runs: the target of ~/.local/bin/claude (a new version after an
    /// update), else its change time.
    nonisolated static func claudeStamp() -> String? {
        let p = SBPaths.home + "/.local/bin/claude"
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: p) { return dest }
        if let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date {
            return String(d.timeIntervalSince1970)
        }
        return nil
    }
}
