import Foundation

/// The Claude app's Code sessions on this Mac. The app keeps one file per session in
/// ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json
/// (its name, folder, conversation id, archived or not), and runs Claude Code for the sessions
/// you opened there as background programs, without a terminal. Their conversations are in the
/// projects folder all logins share, so Switchboard can resume them here.
///
/// This is the app's own file format. When an update changes it, fewer sessions show here;
/// nothing else breaks. A test copy (SWITCHBOARD_DATA) reads only SWITCHBOARD_CLAUDE_APP.
enum SBClaudeApp {
    struct Session {
        let sid: String
        let title: String
        let cwd: String?
        let lastActivity: Double
        /// The app's one-line wrap-up of the last turn.
        let wrapUp: String?
        /// The Switchboard login of the app's Claude account (nil: not one of the three).
        let loginDir: String?
    }

    /// The sessions that are not archived there and whose conversation is on this Mac.
    /// `complete` is false when a file could not be read (it may be half written): then
    /// sessions that seem gone are kept until the next look.
    struct Index {
        var sessions: [Session] = []
        var complete = true
    }

    static let root: String? = {
        if let p = ProcessInfo.processInfo.environment["SWITCHBOARD_CLAUDE_APP"], !p.isEmpty { return p }
        return SBPaths.overridden ? nil : SBPaths.home + "/Library/Application Support/Claude/claude-code-sessions"
    }()

    private static let lock = NSLock()
    /// Parsed files by path, kept while their modification time is the same (some are 1 MB).
    private static var parsed: [String: (mtime: Double, session: Session?)] = [:]
    /// The app's sessions at the last look, by conversation id.
    private static var known: [String: Session] = [:]

    /// Read the app's session files (only the ones that changed since the last look).
    static func index() -> Index {
        var out = Index()
        guard let root, let accounts = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            lock.lock(); known = [:]; lock.unlock()
            return out
        }
        let logins = SBLogins.byAccount()
        var seen = Set<String>()
        for account in accounts {
            let accDir = root + "/" + account
            for org in (try? FileManager.default.contentsOfDirectory(atPath: accDir)) ?? [] {
                let dir = accDir + "/" + org
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                where f.hasPrefix("local_") && f.hasSuffix(".json") {
                    let path = dir + "/" + f
                    seen.insert(path)
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                          let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
                    lock.lock()
                    let hit = parsed[path]
                    lock.unlock()
                    var session: Session?
                    if let hit, hit.mtime == m {
                        session = hit.session
                    } else {
                        guard let j = SBFiles.readJSON(path) as? [String: Any] else { out.complete = false; continue }
                        session = parse(j, loginDir: logins[account])
                        lock.lock()
                        parsed[path] = (m, session)
                        lock.unlock()
                    }
                    if let s = session { out.sessions.append(s) }
                }
            }
        }
        lock.lock()
        parsed = parsed.filter { seen.contains($0.key) }
        known = Dictionary(out.sessions.map { ($0.sid, $0) }, uniquingKeysWith: { a, b in a.lastActivity >= b.lastActivity ? a : b })
        lock.unlock()
        return out
    }

    private static func parse(_ j: [String: Any], loginDir: String?) -> Session? {
        if j["isArchived"] as? Bool == true { return nil }
        // A side chat ("btw") is a short fork of another session, not a session of its own.
        if let from = j["spawnedFrom"] as? [String: Any], from["sideSession"] as? Bool == true || from["btw"] as? Bool == true {
            return nil
        }
        let ids = [j["lastAssistantCliSessionId"], j["cliSessionId"]].compactMap { $0 as? String }.filter(SBBackground.isUUID)
        // Only conversations on this Mac (not the ones that run in the cloud or over SSH).
        guard let sid = ids.first(where: { SBBackground.transcriptPath($0) != nil }) else { return nil }
        let ms = (j["lastActivityAt"] as? Double) ?? (j["createdAt"] as? Double) ?? 0
        let wrap = ((j["turnWrapUp"] as? [String: Any])?["description"] as? String)
            ?? ((j["postTurnSummary"] as? [String: Any])?["status_detail"] as? String)
        return Session(sid: sid, title: (j["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       cwd: j["cwd"] as? String, lastActivity: ms / 1000,
                       wrapUp: wrap.flatMap { $0.isEmpty ? nil : $0 }, loginDir: loginDir)
    }

    /// Claude Code programs the Claude app runs now, for its sessions at the last look.
    /// (A test copy with its own app folder never sees the real app's programs.)
    static func agents() -> [SBBackground.Agent] {
        lock.lock()
        let sessions = known
        lock.unlock()
        guard !sessions.isEmpty else { return [] }
        var out: [SBBackground.Agent] = []
        var taken = Set<String>()
        for pid in SBProcesses.allPIDs() {
            guard SBProcesses.name(Int(pid)) == "claude", SBProcesses.ttyDevice(pid) == nil, let (args, env) = SBProcesses.argsAndEnv(pid),
                  env["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop", SBProcesses.agentKind(args) == "claude" else { continue }
            let configDir = SBLogins.norm(env["CLAUDE_CONFIG_DIR"])
            let ids = [SBBackground.claudeSessionFile(configDir, Int(pid)), SBBackground.sessionIDArgument(kind: "claude", args)]
            guard let sid = ids.compactMap({ $0 }).first(where: { sessions[$0] != nil }), let s = sessions[sid],
                  taken.insert(sid).inserted else { continue }
            let t = SBBackground.transcript(sid)
            out.append(SBBackground.Agent(pid: Int(pid), kind: "claude", tty: "app:\(pid)", loginDir: s.loginDir ?? configDir,
                                          sid: sid, cwd: SBProcesses.cwd(pid) ?? s.cwd, branch: nil,
                                          transcriptTitle: s.title.isEmpty ? t.title : s.title, transcriptMtime: t.mtime,
                                          inClaudeApp: true))
        }
        return out
    }
}
