import AppKit

/// Back and forward between sessions, like a browser: ⌘[ and ⌘], the mouse's back and forward
/// buttons, and the sidebar's ‹ › buttons. History (the clock button) lists the sessions behind
/// and ahead of the one in front, and jumps to any of them.
///
/// - A session you stayed on for at least a second counts as a visit (stepping through the list
///   with ⌘↓ does not fill the history).
/// - Each session is in the history once, at its latest place.
/// - Back and forward skip sessions that are no longer running; History shows them as closed,
///   and clicking one reopens it.
@MainActor
final class SessionHistory {
    static let shared = SessionHistory()

    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    private(set) var current: String?
    private var currentSince = Date()
    /// The session a back, forward or History jump is going to (its arrival is not a new visit).
    private var arriving: String?

    static let limit = 50
    private static let defaultsKey = "sessions.history"

    init() {
        let d = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        back = d["back"] as? [String] ?? []
        forward = d["forward"] as? [String] ?? []
        current = d["current"] as? String
    }

    /// The session in front changed (SessionsStore.refreshFocus).
    func visited(_ key: String) {
        guard key != current else { return }
        if let a = arriving {
            arriving = nil
            if a == key {
                current = key
                currentSince = Date()
                changed()
                return
            }
        }
        // The session you leave goes behind you, once, if you stayed on it (passing through on
        // the way to another does not count, and does not drop its earlier visit either).
        if let c = current, Date().timeIntervalSince(currentSince) >= 1 {
            back.removeAll { $0 == c }
            back.append(c)
        }
        forward.removeAll()
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        current = key
        currentSince = Date()
        changed()
    }

    var canGoBack: Bool { back.contains { $0 != current && isOpen($0) } }
    var canGoForward: Bool { forward.contains(where: isOpen) }

    func goBack(_ via: String = "back") {
        guard let i = back.lastIndex(where: { $0 != current && isOpen($0) }) else { return }
        jump(toBack: i, via: via)
    }

    func goForward(_ via: String = "forward") {
        guard let i = forward.firstIndex(where: isOpen) else { return }
        jump(toForward: i, via: via)
    }

    /// Like a browser's history list: the sessions passed over move to the other side.
    func jump(toBack i: Int, via: String = "History") {
        guard back.indices.contains(i) else { return }
        let target = back[i]
        forward = Array(back[(i + 1)...]) + (current.map { [$0] } ?? []) + forward
        back = Array(back[..<i])
        arrive(target, via: via)
    }

    func jump(toForward i: Int, via: String = "History") {
        guard forward.indices.contains(i) else { return }
        let target = forward[i]
        back = back + (current.map { [$0] } ?? []) + Array(forward[..<i])
        forward = Array(forward[(i + 1)...])
        arrive(target, via: via)
    }

    private func arrive(_ key: String, via: String) {
        // A session that stopped running drops out of what you step over (it stays in the
        // list as closed; History reopens it when you pick it).
        back.removeAll { $0 == key }
        forward.removeAll { $0 == key }
        current = key
        currentSince = Date()
        arriving = key
        changed()
        SessionsStore.shared.open(key: key, via: via)
    }

    /// A session's key changes when its conversation id arrives (a new session's first key →
    /// claude:<id>): keep its place.
    func remap(_ rows: [SessionItem]) {
        var moved = false
        for r in rows {
            guard let was = r.was, was != r.k else { continue }
            if back.contains(was) || forward.contains(was) || current == was {
                back = back.map { $0 == was ? r.k : $0 }
                forward = forward.map { $0 == was ? r.k : $0 }
                if current == was { current = r.k }
                moved = true
            }
        }
        if moved { changed() }
    }

    private func isOpen(_ key: String) -> Bool {
        SessionsStore.shared.payload?.s.first(where: { $0.k == key })?.isOpen ?? false
    }

    private func changed() {
        UserDefaults.standard.set(["back": back, "forward": forward, "current": current ?? ""], forKey: Self.defaultsKey)
        SessionsWeb.shared.setHistory(back: canGoBack, forward: canGoForward)
    }

    // MARK: The History menu

    /// Forward (farthest at the top), the session in front (checked), then back, latest first.
    func menu(_ build: (String, Bool, @escaping () -> Void) -> NSMenuItem) -> NSMenu {
        let menu = NSMenu()
        let rows = SessionsStore.shared.payload?.s ?? []
        func title(_ k: String) -> String {
            guard let s = rows.first(where: { $0.k == k }) else { return "A session that is gone" }
            var t = s.n
            if let lg = s.lg, !lg.isEmpty { t += "  ·  " + lg }
            if !s.isOpen { t += "  ·  closed" }
            return t
        }
        func header(_ text: String) {
            let h = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        let known = Set(rows.map(\.k))
        let fwd = Array(forward.prefix(20))
        if !fwd.isEmpty {
            header("Forward")
            for (i, k) in fwd.enumerated().reversed() where known.contains(k) {
                menu.addItem(build(title(k), false) { SessionHistory.shared.jump(toForward: i, via: "the History menu") })
            }
            menu.addItem(.separator())
        }
        if let c = current, known.contains(c) {
            let item = build(title(c), true) {}
            item.isEnabled = false
            menu.addItem(item)
        }
        let backs = Array(back.enumerated().reversed().filter { $0.element != current }.prefix(20))
        if !backs.isEmpty {
            menu.addItem(.separator())
            header("Back")
            for (i, k) in backs where known.contains(k) && k != current {
                menu.addItem(build(title(k), false) { SessionHistory.shared.jump(toBack: i, via: "the History menu") })
            }
        }
        if menu.items.isEmpty { header("No sessions visited yet") }
        return menu
    }
}
