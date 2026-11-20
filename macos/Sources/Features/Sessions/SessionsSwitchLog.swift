import AppKit

/// Why the session in front changed: one line per change in `<data>/switches.log` (the last
/// 500). When Switchboard shows another session than you expect, the log names what did it: a
/// click on the sidebar (and whether that click brought Switchboard back from another app), a
/// key, back or forward, an API call, or AppKit on its own (with the key or click it handled).
@MainActor
enum SessionSwitchLog {
    private static var reason: (text: String, at: Date)?
    private static var event: (text: String, at: Date)?
    /// The session in front (its key and name), kept while Switchboard is in the background.
    private static var front: (k: String, n: String)?
    /// When Switchboard last came back from another app.
    static var activeSince = Date.distantPast
    private static var lastLine = (text: "", at: Date.distantPast)

    static var path: String { SBPaths.data + "/switches.log" }

    /// A Switchboard action is about to show a session.
    static func because(_ text: String) { reason = (text, Date()) }

    /// The same, unless a more specific reason came just before (the sidebar, a key).
    static func becauseIfNone(_ text: String) {
        if let r = reason, Date().timeIntervalSince(r.at) < 1 { return }
        because(text)
    }

    /// A window became key or the app came back: remember the key or click AppKit handled.
    static func noteEvent(_ prefix: String = "") { event = (prefix + describe(NSApp.currentEvent), Date()) }

    /// The session in front is now `s` (SessionsStore.refreshFocus).
    static func front(_ s: SessionItem) {
        guard s.k != front?.k, s.was == nil || s.was != front?.k else { front = (s.k, s.n); return }
        defer { front = (s.k, s.n) }
        guard let was = front else { return }
        let now = Date()
        var why: String
        if let r = reason, now.timeIntervalSince(r.at) < 3 { why = r.text }
        else if let e = event, now.timeIntervalSince(e.at) < 3 { why = "no Switchboard action; AppKit: " + e.text }
        else { why = "no Switchboard action and no key or click" }
        if !NSApp.isActive { why += " (Switchboard in the background)" }
        reason = nil
        line("“\(was.n)” (\(was.k.suffix(4))) → “\(s.n)” (\(s.k.suffix(4))): \(why)")
    }

    /// One line in the log (the same line again within 2 s is left out).
    static func line(_ text: String) {
        let now = Date()
        guard text != lastLine.text || now.timeIntervalSince(lastLine.at) > 2 else { return }
        lastLine = (text, now)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let row = "\(f.string(from: now))  \(text)\n"
        var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(String(row.dropLast()))
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func describe(_ e: NSEvent?) -> String {
        guard let e else { return "no event" }
        switch e.type {
        case .keyDown:
            let f = e.modifierFlags
            var m = ""
            if f.contains(.control) { m += "⌃" }
            if f.contains(.option) { m += "⌥" }
            if f.contains(.shift) { m += "⇧" }
            if f.contains(.command) { m += "⌘" }
            let names: [UInt16: String] = [48: "⇥", 36: "↩", 53: "esc", 126: "↑", 125: "↓", 123: "←", 124: "→"]
            return "key \(m)\(names[e.keyCode] ?? e.charactersIgnoringModifiers ?? "?")"
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown:
            var place = "the window"
            if let w = e.window, let root = w.contentView?.superview ?? w.contentView,
               let hit = root.hitTest(root.convert(e.locationInWindow, from: nil)) {
                place = where_(hit)
            }
            let what = e.type == .leftMouseDown || e.type == .leftMouseUp ? "click" : "mouse button \(e.buttonNumber + 1)"
            return "\(what) on \(place)"
        case .appKitDefined, .systemDefined:
            return "app switch (⌘⇥, the Dock, or a click in the window)"
        default:
            return "event type \(e.type.rawValue)"
        }
    }

    private static func where_(_ view: NSView) -> String {
        var v: NSView? = view
        while let x = v {
            if x is SessionsWebView { return "the sidebar" }
            if x is DocWebView { return "the page pane" }
            if x is Ghostty.SurfaceView { return "a terminal" }
            v = x.superview
        }
        return String(describing: type(of: view))
    }
}
