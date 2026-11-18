import Foundation

// The session registry: every coding-agent session, open or closed, with its name,
// class, labels, login, folder and conversation id. Kept on disk so it survives
// restarts. The file format is the one the old Python helper wrote
// (~/.config/session-inbox/registry.json), so nothing is lost in the move.

/// Where the tracker keeps its files. SWITCHBOARD_DATA points a test copy elsewhere.
enum SBPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let overridden: Bool = !(ProcessInfo.processInfo.environment["SWITCHBOARD_DATA"] ?? "").isEmpty
    static let data: String = {
        let p = ProcessInfo.processInfo.environment["SWITCHBOARD_DATA"] ?? ""
        let dir = p.isEmpty ? home + "/.config/session-inbox" : p
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let registry = data + "/registry.json"
    static let summaries = data + "/summary-cache-v3.json"
    static let usageHistory = data + "/usage-history.json"
    /// Artifact links per session; the Claude Code hook (session-inbox/hooks) appends here too.
    static let artifacts = data + "/artifacts.jsonl"
    static let artifactOffsets = data + "/artifact-offsets.json"
    static let restart = data + "/app-restart.json"

    static func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
    static func expand(_ p: String) -> String { p.hasPrefix("~") ? home + p.dropFirst(1) : p }
}

/// The three Claude logins (config folders).
enum SBLogins {
    static let dirs = ["~/.claude", "~/.claude-ccl", "~/.claude-ccm"]
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func norm(_ configDir: String?) -> String {
        guard let d = configDir, !d.isEmpty else { return "~/.claude" }
        var t = SBPaths.tilde(d)
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// The email of a login, read from its .claude.json (the folder name if unknown).
    static func email(_ dir: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[dir] { return hit }
        let path = dir == "~/.claude" ? SBPaths.home + "/.claude.json" : SBPaths.expand(dir) + "/.claude.json"
        var email: String?
        if let data = FileManager.default.contents(atPath: path),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let acc = j["oauthAccount"] as? [String: Any] {
            email = acc["emailAddress"] as? String
        }
        cache[dir] = email ?? dir
        return cache[dir]!
    }

    /// simplero.com, corre.li, correli.me.
    static func short(_ dir: String?) -> String {
        let e = email(dir ?? "~/.claude")
        guard let at = e.firstIndex(of: "@") else { return e }
        return String(e[e.index(after: at)...])
    }

    /// Claude account id → login folder.
    static func byAccount() -> [String: String] {
        var out: [String: String] = [:]
        for d in dirs {
            let f = d == "~/.claude" ? SBPaths.home + "/.claude.json" : SBPaths.expand(d) + "/.claude.json"
            if let data = FileManager.default.contents(atPath: f),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let acc = (j["oauthAccount"] as? [String: Any])?["accountUuid"] as? String {
                out[acc] = d
            }
        }
        return out
    }
}

/// What Haiku said about the end of a session's terminal.
struct SBSummary: Codable, Equatable {
    var title: String?
    var said: String?
    var next_step: String?
    var kind: String?
    var urgent: Bool?
    var replies: [SBReply]?

    init(from decoder: Decoder) throws {
        // Lenient: the model sometimes answers "urgent": "false" or replies as plain strings.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return String(n) }
            return nil
        }
        title = str(.title)
        said = str(.said)
        next_step = str(.next_step)
        kind = str(.kind)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .urgent) { urgent = b } else { urgent = str(.urgent).map { $0.lowercased() == "true" } }
        replies = try? c.decodeIfPresent([SBReply].self, forKey: .replies)
    }
}

struct SBReply: Codable, Equatable {
    var label: String?
    var send: String?

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            label = s
            send = s
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        send = try? c.decodeIfPresent(String.self, forKey: .send)
    }
}

/// One session in the registry. Field names are the registry file's keys.
struct SBEntry: Codable {
    var key: String
    var agent: String?
    var session_id: String?
    var name: String?
    var cls: String?
    var labels: [String]?
    var login_dir: String?
    var first_seen: Double?
    var custom_name: Bool?
    var cwd: String?
    var branch: String?
    var open: Bool?
    var closed_at: Double?
    var closed_reason: String?
    var opening_at: Double?
    var workspace_id: String?
    var surface_id: String?
    var pid: Int?
    var last_seen: Double?
    var resume_cmd: String?
    var backend: String?
    var screen: String?
    var working_line: String?
    var last_message: String?
    var last_message_at: Double?
    var last_activity: Double?
    var artifacts: [String]?
    var summary: SBSummary?
    var summary_key: String?
    var split: Bool?
    var state: String?
    var parked: Bool?
    var archived: Bool?
    var archived_at: Double?
    var ack_key: String?
    var was: String?
    var closing: String?
    var tab_title: String?
    var shared_ws: Bool?

    /// The end of the terminal, for the summary. Not saved.
    var tail: String? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case key, agent, session_id, name, cls, labels, login_dir, first_seen, custom_name, cwd, branch, open,
             closed_at, closed_reason, opening_at, workspace_id, surface_id, pid, last_seen, resume_cmd, backend,
             screen, working_line, last_message, last_message_at, last_activity, artifacts, summary, summary_key,
             split, state, parked, archived, archived_at, ack_key, was, closing, tab_title, shared_ws
    }

    init(key: String, agent: String?) {
        self.key = key
        self.agent = agent
    }

    /// Lenient: a field of an unexpected type is dropped, never the whole session.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        key = v(.key) ?? ""
        agent = v(.agent); session_id = v(.session_id); name = v(.name); cls = v(.cls); labels = v(.labels)
        login_dir = v(.login_dir); first_seen = v(.first_seen); custom_name = v(.custom_name); cwd = v(.cwd)
        branch = v(.branch); open = v(.open); closed_at = v(.closed_at); closed_reason = v(.closed_reason)
        opening_at = v(.opening_at); workspace_id = v(.workspace_id); surface_id = v(.surface_id); pid = v(.pid)
        last_seen = v(.last_seen); resume_cmd = v(.resume_cmd); backend = v(.backend); screen = v(.screen)
        working_line = v(.working_line); last_message = v(.last_message); last_message_at = v(.last_message_at)
        last_activity = v(.last_activity); artifacts = v(.artifacts); summary = v(.summary); summary_key = v(.summary_key)
        split = v(.split); state = v(.state); parked = v(.parked); archived = v(.archived); archived_at = v(.archived_at)
        ack_key = v(.ack_key); was = v(.was); closing = v(.closing); tab_title = v(.tab_title); shared_ws = v(.shared_ws)
    }

    var isOpen: Bool { open == true }
}

/// The registry file: sessions plus the class and label lists.
struct SBRegistry {
    var sessions: [String: SBEntry] = [:]
    var classes = ["Management", "Brain", "Work", "Machine"]
    var labels = ["later", "ui", "security", "review"]
    /// Entries this build could not read: written back unchanged, never lost.
    var unreadable: [String: Any] = [:]
    /// Fields of an entry this build does not use (from the Python helper, or a newer
    /// build): written back as they were.
    var extraFields: [String: [String: Any]] = [:]
    /// Top-level keys this build does not use (kept as they were).
    var extra: [String: Any] = [:]

    static func load() -> SBRegistry {
        var r = SBRegistry()
        guard let data = FileManager.default.contents(atPath: SBPaths.registry),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return r }
        let decoder = JSONDecoder()
        let known = Set(SBEntry.CodingKeys.allCases.map(\.rawValue)).union(["tail"])
        for (k, v) in (top["sessions"] as? [String: Any]) ?? [:] {
            if let raw = v as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: raw),
               var e = try? decoder.decode(SBEntry.self, from: d) {
                e.key = k
                r.sessions[k] = e
                let extra = raw.filter { !known.contains($0.key) }
                if !extra.isEmpty { r.extraFields[k] = extra }
            } else {
                r.unreadable[k] = v
            }
        }
        if let c = top["classes"] as? [String], !c.isEmpty { r.classes = c }
        if let l = top["labels"] as? [String], !l.isEmpty { r.labels = l }
        for (k, v) in top where !["sessions", "classes", "labels"].contains(k) { r.extra[k] = v }
        return r
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        var sessions: [String: Any] = unreadable
        for (k, e) in self.sessions {
            if let d = try? encoder.encode(e), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                sessions[k] = (extraFields[k] ?? [:]).merging(obj) { _, typed in typed }
            }
        }
        var top = extra
        top["sessions"] = sessions
        top["classes"] = classes
        top["labels"] = labels
        return try? JSONSerialization.data(withJSONObject: top, options: [.sortedKeys])
    }
}

enum SBFiles {
    static let queue = DispatchQueue(label: "switchboard.files")
    private static var lockFD: Int32 = -1

    /// Hold the session list's lock (the file the Python helper also locked) for the life of
    /// the app. False when another program keeps holding it.
    static func takeLock() -> Bool {
        let fd = open(SBPaths.data + "/helper.lock", O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        for _ in 0..<30 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFD = fd
                ftruncate(fd, 0)
                let pid = "\(getpid())"
                _ = pid.withCString { write(fd, $0, strlen($0)) }
                return true
            }
            usleep(100_000)
        }
        close(fd)
        return false
    }

    static func readJSON(_ path: String) -> Any? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// Write a whole file at once (a temporary file, then rename). False when it did not land.
    @discardableResult
    static func writeAtomic(_ data: Data, _ path: String) -> Bool {
        let tmp = path + ".\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data) else { return false }
        guard rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }

    @discardableResult
    static func writeJSON(_ obj: Any, _ path: String) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        return writeAtomic(d, path)
    }
}
