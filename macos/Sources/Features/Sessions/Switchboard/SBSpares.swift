import AppKit
import GhosttyKit

/// Claude started when you open the new-session form ("+ login"), in the folder new sessions
/// start in, in a window that is never shown. While you write the first message it gets to
/// its prompt (about 1.3 s); Enter shows it as the new session and types the message. Nothing
/// runs ahead of time: after the form closes, the spare stays 2 minutes (you may open the form
/// again), then it ends.
///
/// - A spare is not a session: the tracker, the tab list, the API and the handoff on update
///   skip it (`TerminalController.sessionsSpare`).
/// - A spare kept open longer than 30 minutes, or older than the claude program on disk (an
///   update), starts again; so does one in another folder than the one you picked.
/// - SWITCHBOARD_NO_SPARES=1 turns spares off (new sessions start the slower way).
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
    /// The logins to keep a spare for, and until when (forever while the form is open on one).
    private var wanted: [String: Double] = [:]
    private var failedAt: [String: Double] = [:]
    private var lastRecycle: Double = 0
    private var stamp: String?
    private var stampAt: Double = 0
    private let enabled = ProcessInfo.processInfo.environment["SWITCHBOARD_NO_SPARES"] == nil

    /// SWITCHBOARD_SPARE_MAX_AGE (seconds) for checks.
    static let maxAge = Double(ProcessInfo.processInfo.environment["SWITCHBOARD_SPARE_MAX_AGE"] ?? "") ?? 30 * 60
    /// How long a spare stays after the form closes.
    static let keep = 120.0
    /// Claude not at its prompt by then (a dialog, an error): close it.
    static let readyWithin = 90.0
    static let retryAfter = 30.0

    private var now: Double { Date().timeIntervalSince1970 }

    /// The form opened on this login (nil: the form closed). Starts its spare now.
    func want(_ login: String?) {
        let t = now
        for (k, until) in wanted where until == .infinity { wanted[k] = t + Self.keep }
        if let login, SBLogins.dirs.contains(login) { wanted[login] = .infinity }
        tick()
    }

    /// Every scan (and when the form opens or closes): start the spare the form wants, notice
    /// spares that got to their prompt or ended, end the ones no longer wanted.
    func tick() {
        guard enabled, Switchboard.shared.loaded else { return }
        let t = now
        if t - stampAt > 60 { stampAt = t; stamp = Self.claudeStamp() }
        wanted = wanted.filter { $0.value >= t }
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
            // Not wanted any more, or started in another folder than the one you picked.
            if wanted[login] == nil || s.folder != folder {
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
            // Old, or an older claude than the one on disk: renew it (one that got to its prompt).
            let stale = (stamp != nil && s.stamp != stamp) || t - s.started > Self.maxAge
            if stale, s.readyAt != nil, t - lastRecycle > 20 {
                lastRecycle = t
                discard(login, failed: false)
            }
        }
        for login in wanted.keys.sorted() where spares[login] == nil && t - (failedAt[login] ?? 0) > Self.retryAfter {
            start(login, main: main)
        }
    }

    /// The spare of this login in this folder, ready or still starting. The caller shows it as
    /// a new session (and types the first message once Claude is at its prompt).
    func take(_ login: String, folder: String) -> Spare? {
        guard let s = spares[login], s.folder == folder else { return nil }
        spares[login] = nil
        wanted[login] = nil
        s.controller.sessionsSpare = false
        s.controller.window?.isExcludedFromWindowsMenu = false
        s.controller.window?.isRestorable = s.restorable
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
