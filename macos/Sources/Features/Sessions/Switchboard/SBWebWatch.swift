import AppKit
import Darwin
import WebKit

/// The sidebar and the panel are web pages. After Switchboard starts, WebKit's GPU process can
/// hang: the pages are loaded and work, but they never draw (the sidebar stays black). Then a
/// picture of the sidebar fails. This checks that, and when it fails twice in a row it stops
/// Switchboard's own GPU process. WebKit starts a new one at once and the pages draw again.
/// Nothing else is lost: no page reloads, no terminal closes.
@MainActor
enum SBWebWatch {
    private static var timer: Timer?
    private static var failures = 0
    private static var lastFix: Date?
    private static var checking = false

    static func start() {
        guard timer == nil else { return }
        // Soon after the start (when it happens), then now and then.
        for delay in [6.0, 14.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { check() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { check() } }
    }

    private static func check() {
        let web = SessionsWeb.shared.webView
        // Only a sidebar you can see: a hidden one has no picture either.
        guard !checking, let window = web.window, window.isVisible, window.occlusionState.contains(.visible),
              !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 20, web.bounds.height > 20 else { return }
        checking = true
        var answered = false
        let done: (Bool) -> Void = { ok in
            guard !answered else { return }
            answered = true
            checking = false
            if ok { failures = 0; return }
            failures += 1
            if failures >= 2 { fix() }
        }
        web.takeSnapshot(with: nil) { image, _ in
            MainActor.assumeIsolated { done(image != nil) }
        }
        // No answer at all counts as a failure too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { done(false) } }
    }

    static func fix() {
        failures = 0
        if let last = lastFix, Date().timeIntervalSince(last) < 180 { return }   // at most once in 3 minutes
        stopGPU()
    }

    /// Stops this app's GPU processes and returns their ids.
    @discardableResult
    static func stopGPU() -> [pid_t] {
        lastFix = Date()
        let pids = gpuProcesses()
        for pid in pids { kill(pid, SIGTERM) }
        SessionSwitchLog.did("the sidebar did not draw: stopped WebKit's GPU process \(pids.map(String.init).joined(separator: ", ")) (WebKit starts a new one)")
        return pids
    }

    /// WebKit GPU processes that belong to this app (macOS keeps track of which app an XPC
    /// service runs for), never another app's.
    static func gpuProcesses() -> [pid_t] {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return [] }
        let responsible = unsafeBitCast(sym, to: Responsible.self)
        let me = getpid()
        return SBProcesses.allPIDs().filter { pid in
            guard pid != me, SBProcesses.name(Int(pid)) == "com.apple.WebKit.GPU" else { return false }
            return responsible(pid) == me
        }
    }
}
