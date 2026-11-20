import CryptoKit
import Foundation

/// Slow work for the session tracker, done off the main thread: finding the agent
/// processes in the app's terminals, reading Claude's transcripts, asking Haiku for
/// a summary, reading plan usage, and indexing artifact links.
enum SBBackground {
    // MARK: Agent processes

    /// One coding agent running in one of the app's terminals.
    struct Agent {
        let pid: Int
        let kind: String
        let tty: String
        let loginDir: String
        /// The conversation id: Claude's session file, else --resume / --session-id.
        let sid: String?
        let cwd: String?
        let branch: String?
        /// The /rename name of a Claude conversation.
        let transcriptTitle: String?
        let transcriptMtime: Double?
        /// A program the Claude app runs (no terminal), not one in a terminal.
        var inClaudeApp = false
    }

    private static let lock = NSLock()
    private static var slowCache: [Int: (at: Double, cwd: String?, branch: String?)] = [:]
    private static var transcriptCache: [String: (path: String, mtime: Double, title: String?)] = [:]

    /// The agents running in terminals with these tty names (one per terminal: the oldest).
    static func agents(onTTYs ttys: [String]) -> [Agent] {
        var devToTTY: [UInt32: String] = [:]
        for t in ttys { if let d = SBProcesses.deviceOf(ttyPath: t) { devToTTY[d] = t } }
        guard !devToTTY.isEmpty else { return [] }
        var best: [String: (pid: pid_t, kind: String, args: [String], env: [String: String])] = [:]
        for pid in SBProcesses.allPIDs() {
            guard let dev = SBProcesses.ttyDevice(pid), let tty = devToTTY[dev],
                  let (args, env) = SBProcesses.argsAndEnv(pid), let kind = SBProcesses.agentKind(args) else { continue }
            if let cur = best[tty], cur.pid < pid { continue }
            best[tty] = (pid, kind, args, env)
        }
        let now = Date().timeIntervalSince1970
        lock.lock()
        let live = Set(best.values.map { Int($0.pid) })
        slowCache = slowCache.filter { live.contains($0.key) }
        lock.unlock()
        var out: [Agent] = []
        for (tty, p) in best {
            let pid = Int(p.pid)
            let loginDir = SBLogins.norm(p.env["CLAUDE_CONFIG_DIR"])
            let argSid = sessionIDArgument(kind: p.kind, p.args)
            let fileSid = p.kind == "claude" ? claudeSessionFile(loginDir, pid) : nil
            let sid = fileSid ?? argSid
            lock.lock()
            var slow = slowCache[pid]
            lock.unlock()
            if slow == nil || now - slow!.at >= 30 {
                let cwd = SBProcesses.cwd(p.pid)
                slow = (now, cwd, SBProcesses.gitBranch(cwd))
                lock.lock()
                slowCache[pid] = slow
                lock.unlock()
            }
            let t: (title: String?, mtime: Double?) = p.kind == "claude" ? transcript(sid) : (nil, nil)
            out.append(Agent(pid: pid, kind: p.kind, tty: tty, loginDir: loginDir, sid: sid, cwd: slow?.cwd,
                             branch: slow?.branch, transcriptTitle: t.title, transcriptMtime: t.mtime))
        }
        return out
    }

    /// The agents in terminals that are not Switchboard's (cmux, Terminal, an editor): one per
    /// terminal (the oldest), only those with a conversation id. Processes without a terminal
    /// (`claude -p`) are not sessions and are skipped; the Claude app's are in SBClaudeApp.
    static func agentsElsewhere(notOn ttys: [String]) -> [Agent] {
        let ours = Set(ttys.compactMap { SBProcesses.deviceOf(ttyPath: $0) })
        var best: [UInt32: (pid: pid_t, kind: String, args: [String], env: [String: String])] = [:]
        for pid in SBProcesses.allPIDs() {
            guard let dev = SBProcesses.ttyDevice(pid), !ours.contains(dev),
                  let (args, env) = SBProcesses.argsAndEnv(pid), let kind = SBProcesses.agentKind(args) else { continue }
            if let cur = best[dev], cur.pid < pid { continue }
            best[dev] = (pid, kind, args, env)
        }
        return best.compactMap { dev, p in
            let pid = Int(p.pid)
            let loginDir = SBLogins.norm(p.env["CLAUDE_CONFIG_DIR"])
            let fileSid = p.kind == "claude" ? claudeSessionFile(loginDir, pid) : nil
            guard let sid = fileSid ?? sessionIDArgument(kind: p.kind, p.args) else { return nil }
            let t: (title: String?, mtime: Double?) = p.kind == "claude" ? transcript(sid) : (nil, nil)
            return Agent(pid: pid, kind: p.kind, tty: "dev:\(dev)", loginDir: loginDir, sid: sid, cwd: SBProcesses.cwd(p.pid),
                         branch: nil, transcriptTitle: t.title, transcriptMtime: t.mtime)
        }
    }

    /// The conversation id in an agent's command line: claude --resume / --session-id <uuid>,
    /// codex resume <id>, opencode --session / -s <id>.
    static func sessionIDArgument(kind: String, _ args: [String]) -> String? {
        var found: String?
        for (i, a) in args.enumerated() {
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch kind {
            case "claude":
                if a == "--resume" || a == "--session-id", let n = next, isUUID(n) { found = n }
                for pre in ["--resume=", "--session-id="] where a.hasPrefix(pre) && isUUID(String(a.dropFirst(pre.count))) {
                    found = String(a.dropFirst(pre.count))
                }
            case "codex":
                if a == "resume", let n = next, !n.hasPrefix("-"), n.count >= 8 { found = n }
            case "opencode":
                if a == "--session" || a == "-s", let n = next, !n.hasPrefix("-") { found = n }
                if a.hasPrefix("--session=") { found = String(a.dropFirst("--session=".count)) }
            default:
                break
            }
        }
        return found
    }

    /// A process of this agent kind running this conversation, on a terminal that is not one
    /// of `notOn` (tty devices). `hint` (the pid last seen) is checked first.
    static func findAgent(kind: String, sid: String, notOn: Set<UInt32>, hint: Int?) -> Int? {
        func matches(_ pid: pid_t) -> Bool {
            if let dev = SBProcesses.ttyDevice(pid), notOn.contains(dev) { return false }
            guard let (args, env) = SBProcesses.argsAndEnv(pid), SBProcesses.agentKind(args) == kind else { return false }
            if sessionIDArgument(kind: kind, args) == sid { return true }
            return kind == "claude" && claudeSessionFile(SBLogins.norm(env["CLAUDE_CONFIG_DIR"]), Int(pid)) == sid
        }
        if let h = hint, h > 0, SBProcesses.isAlive(h), matches(pid_t(h)) { return h }
        return SBProcesses.allPIDs().first(where: matches).map(Int.init)
    }

    static func isUUID(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    /// Claude writes <config>/sessions/<pid>.json with the live session id.
    static func claudeSessionFile(_ loginDir: String, _ pid: Int) -> String? {
        let path = SBPaths.expand(loginDir) + "/sessions/\(pid).json"
        return (SBFiles.readJSON(path) as? [String: Any])?["sessionId"] as? String
    }

    /// All logins share one projects folder (~/.claude-ccl/projects links to ~/.claude/projects).
    static var projectRoots: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in SBLogins.dirs {
            let p = (SBPaths.expand(d) + "/projects" as NSString).resolvingSymlinksInPath
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    /// The transcript file of a conversation id.
    static func transcriptPath(_ sid: String) -> String? {
        let fm = FileManager.default
        for root in projectRoots {
            for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let f = root + "/" + dir + "/" + sid + ".jsonl"
                if fm.fileExists(atPath: f) { return f }
            }
        }
        return nil
    }

    /// The /rename name of a Claude conversation (read from the end of its transcript)
    /// and when the transcript last changed.
    static func transcript(_ sid: String?) -> (title: String?, mtime: Double?) {
        guard let sid else { return (nil, nil) }
        lock.lock()
        var hit = transcriptCache[sid]
        lock.unlock()
        let fm = FileManager.default
        if hit == nil || !fm.fileExists(atPath: hit!.path) {
            guard let p = transcriptPath(sid) else { return (nil, nil) }
            hit = (p, 0, nil)
        }
        guard var h = hit,
              let attrs = try? fm.attributesOfItem(atPath: h.path),
              let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return (hit?.title, nil) }
        if m != h.mtime, let fh = FileHandle(forReadingAtPath: h.path) {
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            try? fh.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
            let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
            try? fh.close()
            if let title = lastCustomTitle(tail) { h.title = title }
            h.mtime = m
        }
        lock.lock()
        transcriptCache[sid] = h
        lock.unlock()
        return (h.title, m)
    }

    private static let customTitleRE = try! NSRegularExpression(pattern: #""customTitle":"((?:[^"\\]|\\.)*)""#)

    static func lastCustomTitle(_ text: String) -> String? {
        let ms = customTitleRE.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let m = ms.last, let r = Range(m.range(at: 1), in: text) else { return nil }
        let raw = "\"" + text[r] + "\""
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
    }

    /// Find a Claude conversation on this Mac by its id: its folder, title, first ask
    /// and the account it last ran with.
    typealias Conversation = (cwd: String?, title: String?, firstAsk: String?, account: String?)

    static func lookupConversation(_ sid: String) -> Conversation? {
        guard let f = transcriptPath(sid), let fh = FileHandle(forReadingAtPath: f) else { return nil }
        defer { try? fh.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? NSNumber)?.uint64Value ?? 0
        let head = String(decoding: fh.readData(ofLength: 400_000), as: UTF8.self)
        try? fh.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        var cwd: String?, title: String?, owner: String?, firstAsk: String?
        for line in SBScreen.lines(head) + SBScreen.lines(tail) {
            guard line.contains("\"cwd\"") || line.contains("\"customTitle\"") || line.contains("\"accountUuid\"")
                    || line.contains("\"type\":\"user\"") else { continue }
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            cwd = (j["cwd"] as? String) ?? cwd
            title = (j["customTitle"] as? String) ?? title
            if firstAsk == nil, j["type"] as? String == "user",
               let text = (j["message"] as? [String: Any])?["content"] as? String {
                let t = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !t.isEmpty && !t.hasPrefix("<") { firstAsk = String(t.prefix(70)) }
            }
            owner = (j["accountUuid"] as? String) ?? owner      // the last one wins: the login it ran with last
        }
        return (cwd, title, firstAsk, owner)
    }

    // MARK: Summaries (Haiku)

    static let summaryQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    static let prompt = """
    You read the end of a coding-agent terminal session. Calvin owns it. He runs many agents and
    only wants to hear about things that ONLY HE can do. Agents and SDev (his build system) do all the
    rest by themselves: screenshots, tests, changelogs, CI, PRs, merges after green CI, Linear issues,
    fixing review findings, pulling master, research. Never tell Calvin to do any of that.

    Things only Calvin does: decide what to build or which option (product, visual taste, copy),
    approve a merge of money/auth/data-migration/security work, physical or account steps (hardware,
    logins, payments, API credits), and give feedback on a design or a page the agent asked him to look at.

    Read only the agent's LAST message (after the last line starting with ❯). Earlier text is history.
    Only steps Calvin can take RIGHT NOW count. If the agent says it will still do something first
    ("I will send you a URL", "once CI passes", "after I fix it"), that is not his step yet: next_step is empty.

    Return ONLY a JSON object, no prose, with these keys:
    "title": what this session is about, max 7 words, plain words.
    "said": what the agent last told Calvin, one plain sentence, max 30 words.
    "next_step": the one thing only Calvin can do now, starting with a verb, max 20 words.
      Empty string when the agent's last message needs nothing from him (a report, a done task,
      a step the agent or SDev will take, a heads-up he can ignore).
    "kind": "question" (he must pick or answer), "review" (he must look at or try something),
      "heads_up" (a warning that needs HIS decision), "done" (finished, nothing for him),
      "info" (an answer or status, nothing for him). Use done or info whenever next_step is empty.
    "urgent": true only when Calvin must act soon AND money, customer data, production, or a merge of
      wrong code is at stake. A pending agent task is never urgent.
    "replies": the choices the agent itself offered Calvin, as objects {"label": "...", "send": "..."}, max 3.
      Only when the agent asked him a direct question with explicit answers (yes/no, labelled options A/B/C)
      or the screen ends with a numbered menu (like "1: Learn more  2: Knew this already  0: Dismiss" or "1. Yes").
      label = what the button says, max 6 words; send = the exact text typed into the terminal.
      For a numbered menu, send is just the number and label is "1 · Learn more". For a lettered choice, send "A".
      Never invent requests or follow-up work for the agent (like "check X" or "do Y next").
      [] in every other case, including a report that lists things not yet checked.

    Terminal:

    """

    /// Environment for programs we start: the app's, without terminal-session variables,
    /// with the usual tool folders on PATH.
    static func toolEnv(dropping: Set<String> = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") && !dropping.contains($0.key) }
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", SBPaths.home + "/.local/bin"]
        let path = (extra + (env["PATH"] ?? "").split(separator: ":").map(String.init)).filter { !$0.contains("cmux") }
        var seen = Set<String>()
        env["PATH"] = path.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// Run a program; its output, or nil after `timeout` seconds or on failure to start.
    static func run(_ exe: String, _ args: [String], input: String? = nil, env: [String: String]? = nil, timeout: Double = 10) -> (code: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env ?? toolEnv()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return nil }
        if let input {
            DispatchQueue.global(qos: .utility).async {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Ask Haiku what the end of a terminal says (Claude Code's own login, no MCP, no hooks).
    static func summarize(_ tail: String) -> SBSummary? {
        let claude = SBPaths.home + "/.local/bin/claude"
        guard let r = run(claude, ["-p", "--model", "haiku", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"],
                          input: prompt + tail, env: toolEnv(dropping: ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"]), timeout: 90),
              let open = r.out.firstIndex(of: "{"), let close = r.out.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONDecoder().decode(SBSummary.self, from: Data(r.out[open...close].utf8))
    }

    // MARK: Plan usage per login

    static func keychainService(_ loginDir: String) -> String {
        if loginDir == "~/.claude" { return "Claude Code-credentials" }
        let full = SBPaths.expand(loginDir)
        let hash = SHA256.hash(data: Data(full.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }

    /// Plan usage of one login ({"h5": {"p", "r"}, "wk": {"p", "r"}}), read with the token
    /// Claude Code keeps in the keychain. Never refreshes the token: Claude Code does that.
    static func fetchUsage(_ loginDir: String) -> [String: Any]? {
        guard let r = run("/usr/bin/security", ["find-generic-password", "-s", keychainService(loginDir), "-w"], timeout: 5),
              let j = try? JSONSerialization.jsonObject(with: Data(SBScreen.strip(r.out).utf8)) as? [String: Any],
              let token = (j["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { body = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        guard let body, let d = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func part(_ x: Any?) -> Any {
            guard let x = x as? [String: Any], let u = x["utilization"] as? Double else { return NSNull() }
            return ["p": Int(u.rounded()), "r": x["resets_at"] ?? NSNull()]
        }
        return ["h5": part(d["five_hour"]), "wk": part(d["seven_day"])]
    }

    // MARK: Artifact links

    private static let artifactRE = try! NSRegularExpression(pattern: #"https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9-]{10,}"#)

    /// Find artifact links in each tracked session's transcript, once per new byte, and
    /// record them with the session's login (so the link opener routes old links too).
    static func indexArtifacts(_ sessions: [(sid: String, loginDir: String?)]) {
        var offsets = (SBFiles.readJSON(SBPaths.artifactOffsets) as? [String: Int]) ?? [:]
        var known = Set<String>()
        if let text = try? String(contentsOfFile: SBPaths.artifacts, encoding: .utf8) {
            for line in SBScreen.lines(text) {
                if let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = j["id"] as? String { known.insert(id) }
            }
        }
        var new: [[String: Any]] = []
        let now = Int(Date().timeIntervalSince1970)
        for (sid, loginDir) in sessions {
            guard let f = transcriptPath(sid),
                  let size = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? NSNumber)?.intValue else { continue }
            let start = offsets[f] ?? 0
            guard size > start, let fh = FileHandle(forReadingAtPath: f) else { continue }
            try? fh.seek(toOffset: UInt64(start))
            while true {
                let chunk = fh.readData(ofLength: 8 << 20)
                if chunk.isEmpty { break }
                let text = String(decoding: chunk, as: UTF8.self)
                for m in artifactRE.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = Range(m.range, in: text) else { continue }
                    let url = String(text[r])
                    let id = String(url.split(separator: "/").last ?? "")
                    if known.insert(id).inserted {
                        new.append(["url": url, "id": id, "login_dir": loginDir ?? NSNull(), "session_id": sid, "source": "transcript", "at": now])
                    }
                }
            }
            try? fh.close()
            offsets[f] = size
        }
        if !new.isEmpty {
            let lines = new.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            if let fh = FileHandle(forWritingAtPath: SBPaths.artifacts) {
                fh.seekToEndOfFile()
                fh.write(Data(lines.utf8))
                try? fh.close()
            } else {
                FileManager.default.createFile(atPath: SBPaths.artifacts, contents: Data(lines.utf8))
            }
        }
        SBFiles.writeJSON(offsets, SBPaths.artifactOffsets)
    }

    /// Artifact links per conversation id, oldest first.
    static func artifactsBySession() -> [String: [String]] {
        guard let text = try? String(contentsOfFile: SBPaths.artifacts, encoding: .utf8) else { return [:] }
        var out: [String: [String]] = [:]
        for line in SBScreen.lines(text) {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let sid = j["session_id"] as? String, let url = j["url"] as? String else { continue }
            out[sid, default: []].append(url)
        }
        return out
    }

    // MARK: The old helper

    /// Stop the Python session helper (~/code/session-inbox/server.py) if it runs: this
    /// app does its work now, and two writers would fight over the registry. Only a
    /// Python process whose script is that file is stopped.
    static func stopOldHelper() {
        var pids: [pid_t] = []
        for pid in SBProcesses.allPIDs() where pid != getpid() && isOldHelper(pid) { pids.append(pid) }
        guard !pids.isEmpty else { return }
        pids.forEach { kill($0, SIGTERM) }
        for _ in 0..<30 {
            if !pids.contains(where: { SBProcesses.isAlive(Int($0)) }) { return }
            usleep(100_000)
        }
        pids.forEach { kill($0, SIGKILL) }
    }

    static func isOldHelper(_ pid: pid_t) -> Bool {
        guard let (args, _) = SBProcesses.argsAndEnv(pid), args.count >= 2,
              (args[0] as NSString).lastPathComponent.lowercased().hasPrefix("python"),
              let script = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return false }
        let path = SBPaths.home + "/code/session-inbox/server.py"
        if script == path || (script as NSString).resolvingSymlinksInPath == path { return true }
        return script == "server.py" && isInSessionInbox(pid)
    }

    private static func isInSessionInbox(_ pid: pid_t) -> Bool {
        (SBProcesses.cwd(pid) ?? "").hasSuffix("/code/session-inbox")
    }
}
