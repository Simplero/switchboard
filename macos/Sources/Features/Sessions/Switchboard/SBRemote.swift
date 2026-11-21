import AppKit
import CryptoKit
import Foundation
import GhosttyKit
import Network

/// The Switchboard iPhone app's way in: it sees every session, reads the conversations,
/// and types into them, from anywhere on your Tailscale network.
///
/// - A WebSocket server on port 4480 (SWITCHBOARD_REMOTE_PORT). Only this Mac
///   (loopback) and Tailscale devices of this Mac's own Tailscale login get in
///   (`tailscale whois`); everyone else on the network or the tailnet is cut off at once.
/// - The phone then signs in with its Simplero login (the mobile API key). The Mac asks
///   Simplero who that is (GET /api/mobile/v1/users/me) and lets in only its owner: the
///   first Simplero person who connects from one of your devices (remote.json).
/// - Messages are JSON. Phone → Mac: hello, watch, screen (on/off), send, keys, op, new.
///   Mac → phone: welcome / denied, sessions (the full list first, then only changed rows
///   and the keys that left), conv (the watched conversation: the end first, then what is
///   added), screen (the watched terminal, while the phone shows it), moved (the watched
///   session's key changed), r (the answer to a request with an id).
@MainActor
final class SBRemote {
    static let shared = SBRemote()

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var timer: Timer?
    private var pushScheduled = false
    private var startedListening = false

    private static let env = ProcessInfo.processInfo.environment
    static let port = UInt16(env["SWITCHBOARD_REMOTE_PORT"] ?? "") ?? 4480
    /// A test copy listens on 127.0.0.1 only.
    static let loopbackOnly = env["SWITCHBOARD_REMOTE_LOOPBACK"] != nil
    /// Simplero hosts whose sign-ins count: production, plus a development host for a test copy.
    static let servers: [String] = ["https://simplero.com"] + [env["SWITCHBOARD_REMOTE_SIMPLERO"]].compactMap { $0 }.filter { !$0.isEmpty }
    static let ownerFile = SBPaths.data + "/remote.json"
    static let conversationQueue = DispatchQueue(label: "switchboard.remote.conversations", qos: .utility)

    struct Person: Codable, Equatable {
        var id: Int
        var name: String
        var server: String
    }

    final class Client: @unchecked Sendable {
        let conn: NWConnection
        var person: Person?
        var device = ""
        var watch: Watch?
        var helloSeen = false
        /// Each session row as this phone last got it, so later messages carry only the changes
        /// (a working session changes every second; the whole list every time would be a lot on cellular).
        var sentRows: [String: Data] = [:]
        var sentUse: Data?
        init(_ conn: NWConnection) { self.conn = conn }
    }

    /// The session the phone has open: its conversation and its terminal screen.
    final class Watch: @unchecked Sendable {
        var key: String
        var surface: String?
        var sid: String?
        var reader: SBConversation.Reader?
        var busy = false
        var lookedAt: Double = 0
        var screen = ""
        /// The phone shows the terminal (its Terminal view, or a session with no conversation).
        var wantsScreen: Bool
        init(key: String, surface: String?, screen: Bool = true) {
            self.key = key
            self.surface = surface
            self.wantsScreen = screen
        }
    }

    // MARK: Start

    func start() {
        guard !startedListening, UserDefaults.standard.object(forKey: "SwitchboardRemote") as? Bool != false else { return }
        startedListening = true
        listen()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            MainActor.assumeIsolated { SBRemote.shared.pollWatches() }
        }
    }

    private func listen() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: Self.port)!
        let made: NWListener?
        if Self.loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            made = try? NWListener(using: params)
        } else {
            made = try? NWListener(using: params, on: port)
        }
        guard let l = made else { retryListen(); return }
        l.newConnectionHandler = { conn in
            Task { @MainActor in SBRemote.shared.accept(conn) }
        }
        l.stateUpdateHandler = { state in
            Task { @MainActor in
                if case .failed = state {
                    // The port is still held (the app before an update is still quitting): try again.
                    l.cancel()
                    if SBRemote.shared.listener === l { SBRemote.shared.listener = nil }
                    SBRemote.shared.retryListen()
                }
            }
        }
        listener = l
        l.start(queue: .main)
    }

    private func retryListen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated { if SBRemote.shared.listener == nil { SBRemote.shared.listen() } }
        }
    }

    // MARK: Connections

    enum Peer {
        case loopback
        case tailscale(String)
    }

    /// Who may connect at all: this Mac, or a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48).
    nonisolated static func peer(_ endpoint: NWEndpoint) -> Peer? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return nil }
            if b[0] == 127 { return .loopback }
            if b[0] == 100 && (b[1] & 0xC0) == 64 { return .tailscale("\(b[0]).\(b[1]).\(b[2]).\(b[3])") }
            return nil
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return nil }
            if a.isLoopback { return .loopback }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return peer(.hostPort(host: .ipv4(IPv4Address(Data(b[12..<16]))!), port: 1))
            }
            if b.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) {
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var raw = in6_addr()
                withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: b) }
                inet_ntop(AF_INET6, &raw, &buf, socklen_t(buf.count))
                return .tailscale(String(cString: buf))
            }
            return nil
        default:
            return nil
        }
    }

    private func accept(_ conn: NWConnection) {
        guard Self.peer(conn.endpoint) != nil else { conn.cancel(); return }
        let c = Client(conn)
        clients[ObjectIdentifier(c)] = c
        conn.stateUpdateHandler = { [weak c] state in
            Task { @MainActor in
                guard let c else { return }
                switch state {
                case .failed, .cancelled: SBRemote.shared.drop(c)
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(c)
        // Sign in within 30 s (Simplero may be slow), or the connection closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak c] in
            MainActor.assumeIsolated {
                if let c, c.person == nil { SBRemote.shared.deny(c, "Signing in took too long. Try again.") }
            }
        }
    }

    private func drop(_ c: Client) {
        c.watch = nil
        clients.removeValue(forKey: ObjectIdentifier(c))
    }

    private func receive(_ c: Client) {
        c.conn.receiveMessage { data, context, _, error in
            Task { @MainActor in
                let shared = SBRemote.shared
                guard shared.clients[ObjectIdentifier(c)] != nil else { return }
                if error != nil { c.conn.cancel(); shared.drop(c); return }
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .close {
                    c.conn.cancel(); shared.drop(c); return
                }
                shared.receive(c)
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    shared.handle(c, msg)
                }
            }
        }
    }

    private func send(_ c: Client, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
        c.conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func deny(_ c: Client, _ why: String) {
        send(c, ["t": "denied", "why": why])
        // A proper close (policy violation), so the phone does not just retry.
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.policyViolation)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        c.conn.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    c.conn.cancel()
                    SBRemote.shared.drop(c)
                }
            }
        })
    }

    private func reply(_ c: Client, _ msg: [String: Any], ok: Bool, _ text: String, extra: [String: Any] = [:]) {
        guard let id = msg["id"] else { return }
        send(c, ["t": "r", "id": id, "ok": ok, "msg": text].merging(extra) { a, _ in a })
    }

    // MARK: Signing in

    private func handle(_ c: Client, _ msg: [String: Any]) {
        let t = msg["t"] as? String ?? ""
        if t == "hello" {
            guard !c.helloSeen else { return }
            c.helloSeen = true
            Task { await signIn(c, msg) }
            return
        }
        guard c.person != nil else { return }
        switch t {
        case "ping": send(c, ["t": "pong"])
        case "watch": watch(c, msg)
        case "screen":
            c.watch?.wantsScreen = msg["on"] as? Bool ?? true
            c.watch?.screen = ""
            pollWatch(c)
        case "send": sendText(c, msg)
        case "keys": keys(c, msg)
        case "new": newSession(c, msg)
        case "op": op(c, msg)
        default: reply(c, msg, ok: false, "Unknown request “\(t)”.")
        }
    }

    private func signIn(_ c: Client, _ msg: [String: Any]) async {
        guard let key = msg["key"] as? String, !key.isEmpty else { return deny(c, "Sign in with Simplero first.") }
        let server = (msg["server"] as? String ?? "https://simplero.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard Self.servers.contains(server) else { return deny(c, "This Mac does not take sign-ins from \(server).") }
        c.device = String((msg["device"] as? String ?? "phone").prefix(80))

        // The device must be yours on Tailscale (or this Mac itself).
        guard let peer = Self.peer(c.conn.endpoint) else { return deny(c, "Not on Tailscale.") }
        if case .tailscale(let ip) = peer {
            let ok = await Task.detached(priority: .userInitiated) { Self.sameTailscaleOwner(ip) }.value
            guard ok else { return deny(c, "This device does not belong to this Mac's Tailscale login.") }
        }

        // Then the Simplero login must be the Mac's owner.
        let person: Person
        switch await Self.whoIs(key: key, server: server) {
        case .person(let p): person = p
        case .rejected: return deny(c, "Simplero did not accept the sign-in. Sign out and sign in again.")
        case .unreachable: return deny(c, "The Mac could not reach Simplero to check your sign-in. Try again in a moment.")
        }
        var owner = Self.readOwner()
        if owner == nil {
            owner = person
            Self.writeOwner(person)
        }
        guard let owner, owner.id == person.id, owner.server == person.server else {
            return deny(c, "This Mac's Switchboard belongs to \(owner?.name ?? "someone else")'s Simplero login.")
        }
        Self.rememberKey(key, person)
        c.person = person
        send(c, welcome(person))
        if let m = sessionsMessage(for: c) { send(c, m) }
    }

    enum Identity {
        case person(Person)
        case rejected
        case unreachable
    }

    private static var verified: [String: (person: Person, at: Double)] = [:]

    private static func keyHash(_ key: String, _ server: String) -> String {
        SHA256.hash(data: Data((server + " " + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Who a mobile API key belongs to, asked of Simplero at most every 6 hours. When
    /// Simplero cannot be reached, a key that worked in the last 30 days still does.
    static func whoIs(key: String, server: String) async -> Identity {
        let h = keyHash(key, server)
        let now = Date().timeIntervalSince1970
        if let hit = verified[h], now - hit.at < 6 * 3600 { return .person(hit.person) }
        var req = URLRequest(url: URL(string: server + "/api/mobile/v1/users/me")!)
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Switchboard/1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .rejected }
            guard status == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (j["id"] as? NSNumber)?.intValue else { return .unreachable }
            let p = Person(id: id, name: j["name"] as? String ?? "you", server: server)
            verified[h] = (p, now)
            return .person(p)
        } catch {
            if let known = knownKeys()[h], now - known.at < 30 * 86400 { return .person(known.person) }
            return .unreachable
        }
    }

    private struct OwnerFile: Codable {
        var owner: Person?
        /// Key hash → when Simplero last said it is the owner's.
        var keys: [String: Double]?
    }

    private static func readFile() -> OwnerFile {
        guard let d = FileManager.default.contents(atPath: ownerFile) else { return OwnerFile() }
        return (try? JSONDecoder().decode(OwnerFile.self, from: d)) ?? OwnerFile()
    }

    private static func writeFile(_ f: OwnerFile) {
        guard let d = try? JSONEncoder().encode(f) else { return }
        _ = SBFiles.writeAtomic(d, ownerFile)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerFile)
    }

    static func readOwner() -> Person? { readFile().owner }

    static func writeOwner(_ p: Person) {
        var f = readFile()
        f.owner = p
        writeFile(f)
    }

    private static func knownKeys() -> [String: (person: Person, at: Double)] {
        let f = readFile()
        guard let owner = f.owner else { return [:] }
        return (f.keys ?? [:]).mapValues { (owner, $0) }
    }

    private static func rememberKey(_ key: String, _ p: Person) {
        var f = readFile()
        var keys = f.keys ?? [:]
        keys[keyHash(key, p.server)] = Date().timeIntervalSince1970
        f.keys = keys
        writeFile(f)
    }

    // MARK: Tailscale

    nonisolated static let tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    nonisolated(unsafe) private static var ownerCache: [String: (login: String, at: Double)] = [:]
    nonisolated private static let ownerLock = NSLock()

    /// True when the device at `ip` is signed in to Tailscale as the same person as this Mac.
    nonisolated static func sameTailscaleOwner(_ ip: String) -> Bool {
        guard let mine = login(of: nil), let theirs = login(of: ip) else { return false }
        return mine == theirs
    }

    /// The Tailscale login of a peer (`nil` ip: this Mac), cached for 10 minutes.
    nonisolated static func login(of ip: String?) -> String? {
        let key = ip ?? "self"
        let now = Date().timeIntervalSince1970
        ownerLock.lock()
        let hit = ownerCache[key]
        ownerLock.unlock()
        if let hit, now - hit.at < 600 { return hit.login }
        var login: String?
        if let ip {
            if let r = SBBackground.run(tailscale, ["whois", "--json", ip], timeout: 8), r.code == 0,
               let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] {
                login = (j["UserProfile"] as? [String: Any])?["LoginName"] as? String
            }
        } else if let r = SBBackground.run(tailscale, ["status", "--json", "--peers=false"], timeout: 8), r.code == 0,
                  let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
                  let uid = ((j["Self"] as? [String: Any])?["UserID"] as? NSNumber)?.stringValue {
            login = ((j["User"] as? [String: Any])?[uid] as? [String: Any])?["LoginName"] as? String
        }
        guard let login, !login.isEmpty else { return nil }
        ownerLock.lock()
        ownerCache[key] = (login, now)
        ownerLock.unlock()
        return login
    }

    // MARK: What the phone gets

    private func welcome(_ p: Person) -> [String: Any] {
        let logins = SBLogins.dirs.map { ["d": $0, "lg": SBLogins.short($0), "email": SBLogins.email($0)] }
        return ["t": "welcome", "v": 1, "mac": Host.current().localizedName ?? "Mac", "user": p.name,
                "logins": logins, "folders": folders()]
    }

    /// Where new sessions usually start: the folders of recent sessions, the most recent first.
    private func folders() -> [String] { Switchboard.shared.usualFolders() }

    /// The sessions for one phone: everything the first time ("full"), then only the rows that
    /// changed and the keys that left the list. Nil when nothing changed.
    private func sessionsMessage(for c: Client, payload: [String: Any]? = nil) -> [String: Any]? {
        let p = payload ?? Switchboard.shared.payloadObject()
        let rows = ((p["s"] as? [[String: Any]]) ?? []).filter { $0["ar"] as? Bool != true }.prefix(150)
        var use: [String: Any] = [:]
        for (d, u) in (p["use"] as? [String: Any]) ?? [:] {
            guard var u = u as? [String: Any] else { continue }
            u.removeValue(forKey: "hist")
            use[d] = u
        }
        let full = c.sentRows.isEmpty
        var now: [String: Data] = [:]
        var changed: [[String: Any]] = []
        for r in rows {
            guard let k = r["k"] as? String, let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { continue }
            now[k] = d
            if full || c.sentRows[k] != d { changed.append(r) }
        }
        let gone = c.sentRows.keys.filter { now[$0] == nil }
        let useData = try? JSONSerialization.data(withJSONObject: use, options: [.sortedKeys])
        let useChanged = useData != c.sentUse
        if !full && changed.isEmpty && gone.isEmpty && !useChanged { return nil }
        c.sentRows = now
        c.sentUse = useData
        var m: [String: Any] = ["t": "sessions", "full": full, "s": changed, "gone": Array(gone),
                                "at": Int(Date().timeIntervalSince1970)]
        if full || useChanged { m["use"] = use }
        return m
    }

    /// The sidebar's data changed: tell the phones (at most a few times a second).
    func sessionsChanged() {
        guard !pushScheduled, clients.values.contains(where: { $0.person != nil }) else { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let shared = SBRemote.shared
                shared.pushScheduled = false
                let payload = Switchboard.shared.payloadObject()
                for c in shared.clients.values where c.person != nil {
                    if let msg = shared.sessionsMessage(for: c, payload: payload) { shared.send(c, msg) }
                }
            }
        }
    }

    // MARK: The session the phone has open

    private func watch(_ c: Client, _ msg: [String: Any]) {
        guard let k = msg["k"] as? String, !k.isEmpty else { c.watch = nil; return }
        let screen = msg["screen"] as? Bool ?? true
        if let w = c.watch, w.key == k { w.wantsScreen = screen; return }
        c.watch = Watch(key: k, surface: msg["sf"] as? String, screen: screen)
        pollWatch(c)
    }

    private func pollWatches() {
        for c in clients.values where c.person != nil && c.watch != nil { pollWatch(c) }
    }

    /// The watched session's entry now. Its key changes when Claude starts a new
    /// conversation in the same terminal (or once a new session's id is known).
    private func entry(for w: Watch) -> SBEntry? {
        let sb = Switchboard.shared
        if let e = sb.entry(w.key) { return e }
        if let sf = w.surface, let e = sb.reg.sessions.values.first(where: { $0.isOpen && $0.surface_id == sf }) { return e }
        return sb.reg.sessions.values.first(where: { $0.was == w.key })
    }

    private func pollWatch(_ c: Client) {
        guard let w = c.watch else { return }
        guard let e = entry(for: w) else { return }
        if e.key != w.key {
            send(c, ["t": "moved", "from": w.key, "to": e.key])
            w.key = e.key
        }
        if e.isOpen, let sf = e.surface_id {
            w.surface = sf
            // The screen only while the phone shows it (it changes every second while Claude works).
            if w.wantsScreen || e.agent != "claude", let screen = SessionsAPI.activeText(sf), screen != w.screen {
                w.screen = screen
                send(c, ["t": "screen", "k": e.key, "text": screen])
            }
        }
        // The conversation: Claude's transcript.
        guard e.agent == "claude", let sid = e.session_id, !w.busy else { return }
        if w.sid != sid {
            w.sid = sid
            w.reader = nil
        }
        let now = Date().timeIntervalSince1970
        let key = e.key
        if let reader = w.reader {
            w.busy = true
            Self.conversationQueue.async {
                let changed = reader.poll()
                Task { @MainActor in
                    w.busy = false
                    guard c.watch === w, let changed, !changed.isEmpty else { return }
                    SBRemote.shared.send(c, ["t": "conv", "k": key, "items": changed.map(\.json)])
                }
            }
        } else if now - w.lookedAt > 3 {
            // No transcript yet (a new session writes it with the first message): look again in a moment.
            w.lookedAt = now
            w.busy = true
            Self.conversationQueue.async {
                let path = SBBackground.transcriptPath(sid)
                let reader = path.map { SBConversation.Reader(path: $0) }
                let items = reader?.start() ?? []
                Task { @MainActor in
                    w.busy = false
                    guard c.watch === w, w.sid == sid, let reader else { return }
                    w.reader = reader
                    SBRemote.shared.send(c, ["t": "conv", "k": key, "reset": true, "items": items.suffix(160).map(\.json)])
                }
            }
        }
    }

    // MARK: Doing things

    private func liveSurface(_ c: Client, _ msg: [String: Any]) -> (SBEntry, String)? {
        guard let k = msg["k"] as? String else { reply(c, msg, ok: false, "Which session?"); return nil }
        let w = Watch(key: k, surface: msg["sf"] as? String)
        guard let e = entry(for: w), e.isOpen, let sf = e.surface_id, SessionsAPI.surface(id: sf) != nil else {
            reply(c, msg, ok: false, "That session is not running. Reopen it first.")
            return nil
        }
        return (e, sf)
    }

    /// Type a message into the session's terminal, then Enter (a paste, so line breaks stay in the message).
    private func sendText(_ c: Client, _ msg: [String: Any]) {
        guard let (_, sf) = liveSurface(c, msg) else { return }
        let text = (msg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return reply(c, msg, ok: false, "Nothing to send.") }
        let ok = SessionsAPI.sendInput(sf, text: text, enter: true)
        reply(c, msg, ok: ok, ok ? "Sent." : "That terminal is gone.")
    }

    /// Key names the phone can press, as Ghostty `text:` actions (Zig string escapes).
    static let keyText: [String: String] = [
        "esc": "\\x1b", "enter": "\\r", "tab": "\\t", "shift-tab": "\\x1b[Z", "backspace": "\\x7f", "space": " ",
        "up": "\\x1b[A", "down": "\\x1b[B", "right": "\\x1b[C", "left": "\\x1b[D", "ctrl-c": "\\x03",
    ]

    private func keys(_ c: Client, _ msg: [String: Any]) {
        guard let (_, sf) = liveSurface(c, msg), let s = SessionsAPI.surface(id: sf)?.surface else { return }
        let names = msg["keys"] as? [String] ?? []
        for n in names {
            let text: String?
            if let t = Self.keyText[n] { text = t } else if n.count == 1, let ch = n.first, ch.isLetter || ch.isNumber, ch.isASCII { text = n } else { text = nil }
            guard let text else { return reply(c, msg, ok: false, "Unknown key “\(n)”.") }
            let action = "text:" + text
            _ = ghostty_surface_binding_action(s, action, UInt(action.utf8.count))
        }
        reply(c, msg, ok: true, "Sent.")
    }

    /// A new Claude session, with its first message.
    private func newSession(_ c: Client, _ msg: [String: Any]) {
        let login = msg["login"] as? String ?? "~/.claude"
        guard SBLogins.dirs.contains(login) else { return reply(c, msg, ok: false, "Unknown login \(login).") }
        let prompt = (msg["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let r = Switchboard.shared.newClaude(login, focus: false, cwd: msg["cwd"] as? String, prompt: prompt.isEmpty ? nil : prompt)
        reply(c, msg, ok: r.ok, r.message, extra: r.surface.map { ["sf": $0, "k": "surface:" + $0] } ?? [:])
    }

    /// The sidebar's actions the phone offers. Nothing here moves the Mac's window.
    static let ops: Set<String> = ["open", "done", "park", "close", "ack", "rename", "switch"]

    private func op(_ c: Client, _ msg: [String: Any]) {
        let name = msg["op"] as? String ?? ""
        guard Self.ops.contains(name) else { return reply(c, msg, ok: false, "The phone cannot do “\(name)”.") }
        var m = msg
        m["focus"] = false
        Task {
            let (ok, text) = await Switchboard.shared.dispatch(m)
            reply(c, msg, ok: ok, text)
        }
    }
}
