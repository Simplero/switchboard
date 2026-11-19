import AppKit
import Darwin
import GhosttyKit

/// Restart for an update without stopping anything: the terminals' programs keep
/// running.
///
/// Every terminal is a pty. A program sees only its own end of it; while the app's
/// end (the master) stays open, the program never notices that the app went away.
/// So before quitting, the old app gives a copy of each master to a small holder
/// program (switchboard-holder, in the app bundle) and saves each terminal's state
/// (screen, scrollback, cursor, modes) as VT sequences. The old app then quits
/// without ending the programs. The new app takes the masters from the holder,
/// replays each terminal's state into a new terminal on the same pty, and the
/// programs redraw. Whatever cannot be handed over falls back to the normal restart
/// (conversations resume, other tabs come back as shells).
enum SBHandoff {
    static let version = 1
    static var listPath: String { SBPaths.data + "/handoff.json" }
    static var stateDir: String { SBPaths.data + "/handoff" }
    static var holderPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/switchboard-holder").path }

    /// The installed app has the holder, so a restart can keep the programs running.
    static var available: Bool { FileManager.default.isExecutableFile(atPath: holderPath) }

    /// One terminal handed over.
    struct Item: Codable {
        /// Position in the list of fds the holder sends.
        var i: Int
        /// The session (TerminalController.sessionsWorkspace) and the tab it was in.
        var ws: String
        var tab: String
        /// A split pane after the first pane of its tab.
        var split: Bool
        var cwd: String
        var pid: Int32
        /// The tab in front of the window.
        var selected: Bool
        /// The registry key of the session this terminal ran (its agent, or the shell session).
        var key: String?
    }

    struct List: Codable {
        var v: Int
        var at: Double
        var socket: String
        var items: [Item]
    }

    // MARK: Old app

    /// Hand every terminal over to a holder. Returns how many were handed over (0: the
    /// restart stops the programs as before).
    @MainActor
    static func prepare() -> Int {
        guard available else { return 0 }
        try? FileManager.default.removeItem(atPath: stateDir)
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let keyBySurface = Dictionary(Switchboard.shared.reg.sessions.values.compactMap { e in
            e.isOpen ? e.surface_id.map { ($0, e.key) } : nil
        }, uniquingKeysWith: { a, _ in a })
        let shellKeyByWS = Dictionary(Switchboard.shared.reg.sessions.values.compactMap { e in
            e.isOpen && e.agent == "shell" ? (String(e.key.dropFirst("shell:".count)), e.key) : nil
        }, uniquingKeysWith: { a, _ in a })

        // The one window's tabs in order, then any other terminal window.
        var windows = SessionsAPI.mainWindow().map { $0.tabGroup?.windows ?? [$0] } ?? []
        for c in SessionsAPI.allControllers() {
            if let w = c.window, c is TerminalController, !windows.contains(where: { $0 === w }) { windows.append(w) }
        }
        var items: [Item] = []
        var fds: [Int32] = []
        var views: [Ghostty.SurfaceView] = []
        // First hand every pty over: from now on this app reads nothing more from them,
        // so no output is lost between the state saved below and the new app.
        for w in windows {
            guard let controller = w.windowController as? TerminalController else { continue }
            let selected = (w.tabGroup?.selectedWindow ?? w) === w
            let tab = ScriptTab.stableID(controller: controller)
            for (n, view) in (controller.surfaceTree.root?.leaves() ?? []).enumerated() {
                guard let surface = view.surface else { continue }
                var pid: Int32 = 0
                let fd = ghostty_surface_pty_handoff(surface, &pid)
                guard fd >= 0 else { continue }
                let id = view.id.uuidString
                items.append(Item(i: items.count, ws: controller.sessionsWorkspace, tab: tab, split: n > 0, cwd: view.pwd ?? "",
                                  pid: pid, selected: selected && n == 0,
                                  key: keyBySurface[id] ?? shellKeyByWS[controller.sessionsWorkspace]))
                fds.append(fd)
                views.append(view)
            }
        }
        // Output already read is still being drawn: let it land, then save each terminal.
        usleep(100_000)
        for (i, view) in views.enumerated() {
            guard let surface = view.surface else { continue }
            let state = ghostty_surface_dump_vt(surface)
            let data = state.ptr.map { Data(bytes: $0, count: Int(state.len)) } ?? Data()
            ghostty_string_free(state)
            FileManager.default.createFile(atPath: "\(stateDir)/\(i).vt", contents: data)
        }
        guard !items.isEmpty else { return 0 }
        // Short path (a socket path must fit in 104 bytes).
        let socket = NSTemporaryDirectory() + "switchboard-\(getpid()).sock"
        let started = spawnHolder(socket: socket, fds: fds)
        fds.forEach { close($0) }   // the holder has its own copies
        guard started,
              let json = try? JSONEncoder().encode(List(v: version, at: Date().timeIntervalSince1970, socket: socket, items: items)),
              SBFiles.writeAtomic(json, listPath) else { return 0 }
        return items.count
    }

    /// Start the holder with the masters as its fds 3, 4, 5, … and no other fd of ours.
    private static func spawnHolder(socket: String, fds: [Int32]) -> Bool {
        // Move our copies above any target number first, so the dup2s cannot clobber each other.
        let high = fds.map { fcntl($0, F_DUPFD_CLOEXEC, 1000) }
        defer { high.forEach { if $0 >= 0 { close($0) } } }
        guard !high.contains(where: { $0 < 0 }) else { return false }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        for (i, fd) in high.enumerated() { posix_spawn_file_actions_adddup2(&actions, fd, Int32(3 + i)) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Only the fds set up above reach the holder.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let args = [holderPath, socket, "\(fds.count)", "120"]
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, holderPath, &actions, &attr, &cargs, environ)
        guard rc == 0 else { return false }
        // Ready when its socket exists.
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: socket) { return true }
            usleep(25_000)
        }
        return false
    }

    // MARK: New app

    /// Take the terminals from the holder, if the app that ran before handed them over.
    /// Runs off the main thread.
    nonisolated static func receive() -> (items: [Item], fds: [Int32])? {
        guard let data = FileManager.default.contents(atPath: listPath),
              let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        try? FileManager.default.removeItem(atPath: listPath)
        guard list.v == version, Date().timeIntervalSince1970 - list.at < 110, !list.items.isEmpty else { return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(list.socket.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
        }
        var connected = false
        for _ in 0..<40 {
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if rc == 0 { connected = true; break }
            usleep(100_000)
        }
        guard connected, write(s, "GET\n", 4) == 4 else { return nil }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var fds = [Int32](repeating: -1, count: list.items.count)
        var done = false
        while !done {
            guard let (text, got) = receiveMessage(s) else { break }
            if text.hasPrefix("END") { done = true; break }
            guard text.hasPrefix("F"), text.count >= 7,
                  let start = Int(text.dropFirst(1).prefix(3)), let n = Int(text.dropFirst(4).prefix(3)),
                  got.count == n else { got.forEach { close($0) }; break }
            for (k, fd) in got.enumerated() where start + k < fds.count { fds[start + k] = fd }
        }
        guard done, !fds.contains(-1) else {
            fds.forEach { if $0 >= 0 { close($0) } }
            return nil
        }
        _ = write(s, "OK\n", 3)
        return (list.items, fds)
    }

    /// One 8-byte message and the fds that came with it.
    private static func receiveMessage(_ s: Int32) -> (String, [Int32])? {
        var bytes = [UInt8](repeating: 0, count: 8)
        var control = [UInt8](repeating: 0, count: 512)
        var fds: [Int32] = []
        var have = 0
        while have < 8 {
            let n: Int = bytes.withUnsafeMutableBytes { buf in
                control.withUnsafeMutableBytes { ctl in
                    var iov = iovec(iov_base: buf.baseAddress! + have, iov_len: 8 - have)
                    return withUnsafeMutablePointer(to: &iov) { iovp in
                        var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                         msg_control: ctl.baseAddress, msg_controllen: socklen_t(ctl.count), msg_flags: 0)
                        let r = recvmsg(s, &msg, 0)
                        if r > 0 { fds += parseRights(ctl, Int(msg.msg_controllen)) }
                        return r
                    }
                }
            }
            if n <= 0 { fds.forEach { close($0) }; return nil }
            have += n
        }
        return (String(decoding: bytes, as: UTF8.self), fds)
    }

    /// The fds in SCM_RIGHTS control messages (Darwin layout: 12-byte header, 4-byte alignment).
    private static func parseRights(_ ctl: UnsafeMutableRawBufferPointer, _ length: Int) -> [Int32] {
        var out: [Int32] = []
        var off = 0
        while off + 12 <= length {
            let len = Int(ctl.load(fromByteOffset: off, as: UInt32.self))
            let level = ctl.load(fromByteOffset: off + 4, as: Int32.self)
            let type = ctl.load(fromByteOffset: off + 8, as: Int32.self)
            guard len >= 12, off + len <= length else { break }
            if level == SOL_SOCKET && type == SCM_RIGHTS {
                var p = off + 12
                while p + 4 <= off + len {
                    out.append(ctl.load(fromByteOffset: p, as: Int32.self))
                    p += 4
                }
            }
            off += (len + 3) & ~3
        }
        return out
    }

    /// Give each handed-over terminal a new tab (or split) on its old pty, in the old
    /// order and sessions. Returns the registry keys of the sessions that came back this
    /// way, so the normal restore skips them.
    @MainActor
    static func adopt(_ items: [Item], _ fds: [Int32]) -> Set<String> {
        var covered = Set<String>()
        var lastInSession: [String: String] = [:]     // ws → last terminal id (tabs keep their order)
        var lastInTab: [String: String] = [:]         // old tab → its first terminal's new id
        var selectedNew: String?
        for item in items.sorted(by: { $0.i < $1.i }) {
            let fd = fds[item.i]
            let replay = FileManager.default.contents(atPath: "\(stateDir)/\(item.i).vt")
            let pty = SessionsAPI.AdoptPTY(fd: fd, pid: item.pid, replay: replay)
            var newID: String?
            if item.split, let first = lastInTab[item.tab] {
                newID = SessionsAPI.adoptSplit(nextTo: first, adopt: pty)
            } else {
                newID = SessionsAPI.openTab(cwd: item.cwd.isEmpty ? nil : item.cwd, input: nil, env: [:], focus: false,
                                            tabOf: lastInSession[item.ws], adopt: pty, ws: item.ws)?.id
                if let newID { lastInTab[item.tab] = newID }
            }
            guard let newID else { close(fd); continue }
            // The shell reports its folder again at its next prompt; until then, the old one.
            if !item.cwd.isEmpty, let view = SessionsAPI.surface(id: newID), view.pwd == nil { view.pwd = item.cwd }
            lastInSession[item.ws] = newID
            if item.selected { selectedNew = newID }
            if let k = item.key { covered.insert(k) }
        }
        try? FileManager.default.removeItem(atPath: stateDir)
        // The session that was in front is in front again (without taking the screen).
        if let id = selectedNew, let view = SessionsAPI.surface(id: id),
           let w = BaseTerminalController.controller(owning: view)?.window {
            w.tabGroup?.selectedWindow = w
        }
        return covered
    }
}
