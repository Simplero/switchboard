import Foundation
import SQLite3

/// Search inside every conversation on this Mac: Claude Code (the Claude app's Code sessions
/// too), Codex, Grok and OpenCode. Switchboard's own list only knows the sessions it saw; the
/// agents keep every conversation on disk, so this reads those files.
///
/// An index (SQLite full-text) keeps what was said: the prompts and the replies, not tool
/// output, not injected instructions. It is a cache: delete it and the next pass builds it
/// again. The first pass reads everything (gigabytes), so it runs at background priority,
/// on the efficiency cores, and never on the main thread. Later passes read only the files
/// that changed. A conversation that is still being written is read again at most every
/// 15 minutes.
///
/// The agents' file formats are their own. When an update changes one, fewer conversations
/// show here; nothing else breaks.
///
/// A test copy (SWITCHBOARD_DATA) reads only the home folder in SWITCHBOARD_HISTORY_HOME.
///
/// The readers follow Backtrace (https://github.com/amrshawqy/backtrace):
///
///   MIT License. Copyright (c) 2026 Amr Shawqy
///
///   Permission is hereby granted, free of charge, to any person obtaining a copy of this
///   software and associated documentation files (the "Software"), to deal in the Software
///   without restriction, including without limitation the rights to use, copy, modify,
///   merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
///   permit persons to whom the Software is furnished to do so, subject to the following
///   conditions: The above copyright notice and this permission notice shall be included in
///   all copies or substantial portions of the Software.
///
///   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
///   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
///   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
///   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT
///   OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
///   OTHER DEALINGS IN THE SOFTWARE.
final class SBHistory: @unchecked Sendable {
    static let shared = SBHistory()

    /// A conversation in the index.
    struct Doc {
        let key: String        // "<agent>:<id>", the same key Switchboard's list uses
        let agent: String
        let sid: String
        let path: String
        let title: String
        let cwd: String?
        let branch: String?
        let mtime: Double
        /// The Mac that changed it last (Syncthing knows), nil when not synced.
        let machine: String?
        let thisMac: Bool?
    }

    struct Hit {
        let doc: Doc
        /// The words around the match; \u{E000} and \u{E001} mark the words searched for.
        let snippet: String
    }

    struct Results {
        /// Conversations of sessions in Switchboard's list, newest first.
        var inList: [Hit] = []
        /// The newest other conversations.
        var other: [Hit] = []
        /// How many other conversations match in all.
        var otherTotal = 0
    }

    struct Status {
        var busy = false
        var done = 0
        var todo = 0
        var docs = 0
        var lastPassAt: Double = 0
        var lastPassSeconds: Double = 0
    }

    /// The home folder the conversations are in (nil: off, in a test copy without one).
    let home: String?
    let dbPath: String

    private let queue = DispatchQueue(label: "switchboard.history", qos: .background)
    private var writer: OpaquePointer?
    private var reader: OpaquePointer?
    private let readLock = NSLock()
    private let stateLock = NSLock()
    private var state = Status()
    private var started = false
    private var passQueued = false
    private var searchGen = 0

    /// The format of the index. A new number rebuilds it.
    private static let version: Int32 = 1
    /// Text kept per conversation: the start and the end of a long one.
    static let headChars = 100_000, tailChars = 300_000
    /// One message, at most (a long reply is cut).
    static let messageChars = 8_000

    private init() {
        let env = ProcessInfo.processInfo.environment
        if let h = env["SWITCHBOARD_HISTORY_HOME"], !h.isEmpty {
            home = h
        } else {
            home = SBPaths.overridden ? nil : SBPaths.home
        }
        if SBPaths.overridden {
            dbPath = SBPaths.data + "/history-v\(Self.version).sqlite"
        } else {
            let dir = SBPaths.home + "/Library/Caches/Switchboard"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            dbPath = dir + "/history-v\(Self.version).sqlite"
        }
    }

    // MARK: Schedule

    /// Start indexing: the first pass a little after launch, then one every 10 minutes.
    func start() {
        guard home != nil else { return }
        stateLock.lock()
        let first = !started
        started = true
        stateLock.unlock()
        guard first else { return }
        let delay = Double(ProcessInfo.processInfo.environment["SWITCHBOARD_HISTORY_DELAY"] ?? "") ?? 60
        queue.asyncAfter(deadline: .now() + delay) { [self] in loop() }
    }

    private func loop() {
        pass()
        queue.asyncAfter(deadline: .now() + 600) { [self] in loop() }
    }

    /// A search came in: read what changed since the last pass, when that was a while ago.
    func kick() {
        stateLock.lock()
        let due = started && !state.busy && !passQueued && Date().timeIntervalSince1970 - state.lastPassAt > 120
        if due { passQueued = true }
        stateLock.unlock()
        guard due else { return }
        queue.async { [self] in
            stateLock.lock(); passQueued = false; stateLock.unlock()
            pass()
        }
    }

    /// For checks: run a pass now and wait for it.
    func passNow() {
        queue.sync { pass() }
    }

    var status: Status {
        stateLock.lock(); defer { stateLock.unlock() }
        return state
    }

    // MARK: Finding the conversations

    private struct Found {
        let key: String
        let agent: String
        let sid: String
        let path: String
        let mtime: Double
        let size: Int64
    }

    private static func attrs(_ path: String) -> (mtime: Double, size: Int64, dir: Bool, link: Bool)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let link = (st.st_mode & S_IFMT) == S_IFLNK
        if link, stat(path, &st) != 0 { return nil }
        let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (m, Int64(st.st_size), (st.st_mode & S_IFMT) == S_IFDIR, link)
    }

    private static func list(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    private static func real(_ p: String) -> String { (p as NSString).resolvingSymlinksInPath }

    private static let uuidRE = try! NSRegularExpression(pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)

    private static func lastUUID(_ s: String) -> String? {
        let ms = uuidRE.matches(in: s, range: NSRange(s.startIndex..., in: s))
        guard let m = ms.last, let r = Range(m.range, in: s) else { return nil }
        return String(s[r]).lowercased()
    }

    /// Every conversation file, and the agents whose folder could be read (a conversation of
    /// another agent is not dropped from the index just because its folder is missing now).
    private func discover(_ home: String) -> (found: [Found], read: Set<String>) {
        var out: [String: Found] = [:]
        var read = Set<String>()
        func add(_ f: Found) {
            if let old = out[f.key], old.mtime >= f.mtime { return }
            out[f.key] = f
        }

        // Claude Code: <login>/projects/<folder>/<id>.jsonl. All logins can share one projects
        // folder (a link); read each real folder once. Sub-agents' files are one level deeper.
        var claudeRoots: [String] = []
        for name in Self.list(home) where name == ".claude" || name.hasPrefix(".claude-") {
            let p = Self.real(home + "/" + name + "/projects")
            if Self.attrs(p)?.dir == true, !claudeRoots.contains(p) { claudeRoots.append(p) }
        }
        if !claudeRoots.isEmpty { read.insert("claude") }
        for root in claudeRoots {
            for folder in Self.list(root) {
                let dir = root + "/" + folder
                // A folder that links to another one holds the same files.
                guard let a = Self.attrs(dir), a.dir, !a.link else { continue }
                for f in Self.list(dir) where f.hasSuffix(".jsonl") {
                    let sid = String(f.dropLast(6)).lowercased()
                    guard SBBackground.isUUID(sid), let fa = Self.attrs(dir + "/" + f), !fa.dir else { continue }
                    add(Found(key: "claude:" + sid, agent: "claude", sid: sid, path: dir + "/" + f, mtime: fa.mtime, size: fa.size))
                }
            }
        }

        // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl, older ones compressed (.jsonl.zst).
        let codexHome = home + "/.codex"
        for sub in ["sessions", "archived_sessions"] {
            let root = Self.real(codexHome + "/" + sub)
            guard Self.attrs(root)?.dir == true, let e = FileManager.default.enumerator(atPath: root) else { continue }
            read.insert("codex")
            while let rel = e.nextObject() as? String {
                let name = (rel as NSString).lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"),
                      let sid = Self.lastUUID(name.replacingOccurrences(of: ".zst", with: "").replacingOccurrences(of: ".jsonl", with: "")),
                      let fa = Self.attrs(root + "/" + rel), !fa.dir else { continue }
                add(Found(key: "codex:" + sid, agent: "codex", sid: sid, path: root + "/" + rel, mtime: fa.mtime, size: fa.size))
            }
        }

        // Grok: ~/.grok/sessions/<folder>/<id>/ with summary.json and chat_history.jsonl.
        let grokRoot = Self.real(home + "/.grok/sessions")
        if Self.attrs(grokRoot)?.dir == true {
            read.insert("grok")
            for folder in Self.list(grokRoot) {
                let dir = grokRoot + "/" + folder
                guard Self.attrs(dir)?.dir == true else { continue }
                for sid in Self.list(dir) {
                    let s = dir + "/" + sid
                    guard let summary = Self.attrs(s + "/summary.json") else { continue }
                    let chat = Self.attrs(s + "/chat_history.jsonl")
                    add(Found(key: "grok:" + sid, agent: "grok", sid: sid, path: s,
                              mtime: max(summary.mtime, chat?.mtime ?? 0), size: (chat?.size ?? 0) + summary.size))
                }
            }
        }

        // OpenCode: one database. Each session is a row; sub-agents have a parent.
        let ocPath = home + "/.local/share/opencode/opencode.db"
        if Self.attrs(ocPath) != nil, let db = Self.open(ocPath, readOnly: true) {
            read.insert("opencode")
            Self.query(db, "SELECT id, time_updated FROM session WHERE parent_id IS NULL") { row in
                let id = Self.text(row, 0)
                guard !id.isEmpty else { return }
                add(Found(key: "opencode:" + id, agent: "opencode", sid: id, path: ocPath,
                          mtime: sqlite3_column_double(row, 1) / 1000, size: 0))
            }
            sqlite3_close(db)
        }
        return (Array(out.values), read)
    }

    // MARK: Reading a conversation

    private struct Parsed {
        var title: String?
        var cwd: String?
        var branch: String?
        var text = Collector()
        var firstAsk: String?
    }

    /// The text kept of one conversation: the start and the end when it is long.
    struct Collector {
        private var head: [String] = []
        private var headCount = 0
        private var tail: [String] = []
        private var tailCount = 0
        private var recent: [String] = []
        var isEmpty: Bool { head.isEmpty }

        mutating func add(_ raw: String) {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if t.count > SBHistory.messageChars { t = String(t.prefix(SBHistory.messageChars)) + "…" }
            // Some agents record one message twice (an event and a response item).
            if recent.contains(t) { return }
            recent.append(t)
            if recent.count > 3 { recent.removeFirst() }
            if headCount < SBHistory.headChars {
                head.append(t); headCount += t.count
                return
            }
            tail.append(t); tailCount += t.count
            while tailCount > SBHistory.tailChars, tail.count > 1 {
                tailCount -= tail.removeFirst().count
            }
        }

        func body(title: String?) -> String {
            ((title.map { [$0] } ?? []) + head + (tail.isEmpty ? [] : ["…"] + tail)).joined(separator: "\n\n")
        }
    }

    private static let skippedPrompts = ["<environment_context>", "<system-reminder>", "<user_info>", "<permissions instructions>",
                                         "# AGENTS.md instructions", "<local-command-stdout>", "<local-command-stderr>",
                                         "<command-name>", "<command-message>", "Caveat: The messages below"]

    /// Text the person typed, not context an agent put in their name.
    static func isPrompt(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !skippedPrompts.contains { t.hasPrefix($0) }
    }

    private static func unwrap(_ s: String, tag: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<\(tag)>"), t.hasSuffix("</\(tag)>") {
            t = String(t.dropFirst(tag.count + 2).dropLast(tag.count + 3))
        }
        return t
    }

    /// The text blocks of a message's content: a string, or a list of blocks.
    static func textContent(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        guard let items = v as? [[String: Any]] else { return nil }
        let texts = items.compactMap { i -> String? in
            let type = i["type"] as? String
            guard type == nil || type == "text" || type == "input_text" || type == "output_text" else { return nil }
            return (i["text"] as? String) ?? (i["content"] as? String)
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private func parse(_ f: Found, codexTitles: [String: String]) -> Parsed? {
        switch f.agent {
        case "claude": return Self.parseClaude(f.path)
        case "codex": return Self.parseCodex(f.path, title: codexTitles[f.sid])
        case "grok": return Self.parseGrok(f.path)
        case "opencode": return Self.parseOpenCode(f.path, sid: f.sid)
        default: return nil
        }
    }

    // A quick look at the raw line before the JSON is read: most lines (tool output, progress)
    // are skipped without reading them. Quoted values only, so spacing does not matter; a
    // quote inside text is escaped (\"), so text cannot look like one of these.
    private static func needle(_ s: String) -> [UInt8] { Array(("\"" + s + "\"").utf8) }
    private static let nUser = needle("user"), nAssistant = needle("assistant")
    private static let nToolResult = needle("tool_result")
    private static let nCustomTitle = needle("custom-title"), nAITitle = needle("ai-title")
    private static let nUserMessage = needle("user_message"), nAgentMessage = needle("agent_message")
    private static let nMessage = needle("message"), nSessionMeta = needle("session_meta")

    private static func has(_ line: UnsafeRawBufferPointer, _ n: [UInt8]) -> Bool {
        n.withUnsafeBytes { nb in memmem(line.baseAddress, line.count, nb.baseAddress, nb.count) != nil }
    }

    private static func eachLine(_ data: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let n = buf.count
            var start = 0
            while start < n {
                let end: Int
                if let p = memchr(base + start, 0x0A, n - start) { end = base.distance(to: UnsafeRawPointer(p)) } else { end = n }
                if end > start { body(UnsafeRawBufferPointer(start: base + start, count: end - start)) }
                start = end + 1
            }
        }
    }

    private static func json(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    private static func parseClaude(_ path: String) -> Parsed? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        var p = Parsed()
        var custom: String?, ai: String?
        eachLine(data) { line in
            if has(line, nCustomTitle), let j = json(line), let t = j["customTitle"] as? String, !t.isEmpty { custom = t; return }
            if has(line, nAITitle), let j = json(line), let t = j["aiTitle"] as? String, !t.isEmpty { ai = t; return }
            let user = has(line, nUser)
            guard user || has(line, nAssistant) else { return }
            // Tool results are what the tools printed, not the conversation (and the biggest lines).
            if user && has(line, nToolResult) { return }
            guard let j = json(line), let type = j["type"] as? String, type == "user" || type == "assistant",
                  j["isMeta"] as? Bool != true, j["isSidechain"] as? Bool != true else { return }
            if p.cwd == nil, let c = j["cwd"] as? String, !c.isEmpty { p.cwd = c }
            if let b = j["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { p.branch = b }
            guard let text = textContent((j["message"] as? [String: Any])?["content"]) else { return }
            if type == "user" {
                guard isPrompt(text) else { return }
                if p.firstAsk == nil, j["isCompactSummary"] as? Bool != true { p.firstAsk = text }
            }
            p.text.add(text)
        }
        p.title = custom ?? ai
        return p
    }

    private static func readMaybeCompressed(_ path: String) -> Data? {
        guard path.hasSuffix(".zst") else { return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) }
        guard let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zstd)
        proc.arguments = ["-dcq", path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? data : nil
    }

    private static func parseCodex(_ path: String, title: String?) -> Parsed? {
        guard let data = readMaybeCompressed(path) else { return nil }
        var p = Parsed()
        p.title = title
        eachLine(data) { line in
            if p.cwd == nil, has(line, nSessionMeta), let j = json(line), let pl = j["payload"] as? [String: Any] {
                p.cwd = (pl["cwd"] as? String) ?? (pl["working_directory"] as? String)
                p.branch = (pl["git"] as? [String: Any])?["branch"] as? String
                return
            }
            guard has(line, nMessage) || has(line, nUserMessage) || has(line, nAgentMessage),
                  let j = json(line), let pl = j["payload"] as? [String: Any] else { return }
            // Old files: user_message and agent_message events. New ones: "message" response
            // items with a role (some files hold both forms of the same message).
            let role: String?
            switch pl["type"] as? String {
            case "user_message": role = "user"
            case "agent_message": role = "assistant"
            case "message" where j["type"] as? String == "response_item": role = pl["role"] as? String
            default: role = nil
            }
            guard role == "user" || role == "assistant" else { return }
            let text = pl["type"] as? String == "message" ? textContent(pl["content"]) : ((pl["message"] as? String) ?? (pl["text"] as? String))
            guard let text else { return }
            if role == "user" {
                guard isPrompt(text) else { return }
                if p.firstAsk == nil { p.firstAsk = text }
            }
            p.text.add(text)
        }
        return p
    }

    private static func parseGrok(_ dir: String) -> Parsed? {
        var p = Parsed()
        if let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/summary.json")),
           let s = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let t = ((s["generated_title"] as? String) ?? (s["session_summary"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
            p.title = t?.isEmpty == false ? t : nil
            p.cwd = (s["info"] as? [String: Any])?["cwd"] as? String
            p.branch = s["head_branch"] as? String
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/chat_history.jsonl"), options: .mappedIfSafe) {
            eachLine(data) { line in
                let user = has(line, nUser)
                guard user || has(line, nAssistant), let j = json(line), let type = j["type"] as? String,
                      type == "user" || type == "assistant",
                      j["synthetic_reason"] == nil,          // context Grok put in, not typed
                      let raw = textContent(j["content"]) else { return }
                if type == "user" {
                    let text = unwrap(raw, tag: "user_query")
                    guard isPrompt(text) else { return }
                    if p.firstAsk == nil { p.firstAsk = text }
                    p.text.add(text)
                } else {
                    p.text.add(raw)
                }
            }
        }
        return p
    }

    private static func parseOpenCode(_ path: String, sid: String) -> Parsed? {
        guard let db = open(path, readOnly: true) else { return nil }
        defer { sqlite3_close(db) }
        var p = Parsed()
        query(db, "SELECT title, directory FROM session WHERE id = ?", [sid]) { row in
            p.title = text(row, 0)
            p.cwd = text(row, 1)
        }
        query(db, """
            SELECT json_extract(m.data, '$.role'), json_extract(pt.data, '$.text') FROM part pt
            JOIN message m ON m.id = pt.message_id
            WHERE pt.session_id = ? AND json_extract(pt.data, '$.type') = 'text'
            ORDER BY pt.time_created, pt.id
            """, [sid]) { row in
            let role = text(row, 0), t = text(row, 1)
            if role == "user" {
                guard isPrompt(t) else { return }
                if p.firstAsk == nil { p.firstAsk = t }
            }
            p.text.add(t)
        }
        return p
    }

    private static func codexTitles(_ home: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.codex/session_index.jsonl")) else { return [:] }
        var out: [String: String] = [:]
        eachLine(data) { line in
            guard let j = json(line), let id = j["id"] as? String,
                  let t = (j["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
            out[id.lowercased()] = t
        }
        return out
    }

    // MARK: Which Mac changed it (Syncthing)

    /// Conversation folders synced between Macs with Syncthing carry no machine name; Syncthing
    /// records which device changed each file last. This asks the local Syncthing.
    private final class Syncthing {
        let base: URL
        let key: String
        let folders: [(id: String, path: String)]
        let names: [String: String]
        var myID: String?
        var down = false

        init?(home: String) {
            let candidates = ["/Library/Application Support/Syncthing/config.xml", "/.local/state/syncthing/config.xml", "/.config/syncthing/config.xml"]
            guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: URL(fileURLWithPath: home + $0)) }).first,
                  let doc = try? XMLDocument(data: data), let root = doc.rootElement(),
                  let gui = root.elements(forName: "gui").first,
                  let key = gui.elements(forName: "apikey").first?.stringValue, !key.isEmpty,
                  let addr = gui.elements(forName: "address").first?.stringValue, !addr.isEmpty,
                  let base = URL(string: (gui.attribute(forName: "tls")?.stringValue == "true" ? "https://" : "http://") + addr)
            else { return nil }
            self.base = base
            self.key = key
            folders = root.elements(forName: "folder").compactMap { el in
                guard let id = el.attribute(forName: "id")?.stringValue, let p = el.attribute(forName: "path")?.stringValue else { return nil }
                let full = SBHistory.real((p as NSString).expandingTildeInPath)
                return (id, full.hasSuffix("/") ? full : full + "/")
            }.sorted { $0.path.count > $1.path.count }
            var names: [String: String] = [:]
            for el in root.elements(forName: "device") {
                if let id = el.attribute(forName: "id")?.stringValue, let n = el.attribute(forName: "name")?.stringValue, !n.isEmpty {
                    names[String(id.prefix(7))] = n
                }
            }
            self.names = names
        }

        private func get(_ path: String, _ query: [String: String]) -> [String: Any]? {
            guard !down, var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
            if !query.isEmpty {
                c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
                c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            }
            guard let url = c.url else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 3)
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
            let done = DispatchSemaphore(value: 0)
            var out: [String: Any]?
            var failed = false
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if err != nil { failed = true }
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200 {
                    out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
                done.signal()
            }.resume()
            if done.wait(timeout: .now() + 4) == .timedOut { failed = true }
            if failed { down = true }      // not running: stop asking for this pass
            return out
        }

        func machine(_ path: String) -> (name: String, thisMac: Bool)? {
            let full = SBHistory.real(path)
            guard let f = folders.first(where: { full.hasPrefix($0.path) }) else { return nil }
            if myID == nil { myID = (get("rest/system/status", [:])?["myID"] as? String).map { String($0.prefix(7)) } }
            guard let o = get("rest/db/file", ["folder": f.id, "file": String(full.dropFirst(f.path.count))]),
                  let by = (o["global"] as? [String: Any])?["modifiedBy"] as? String, !by.isEmpty else { return nil }
            return (names[by] ?? by, by == myID)
        }
    }

    // MARK: The index

    private func openWriter() -> OpaquePointer? {
        if let writer { return writer }
        guard var db = Self.open(dbPath, readOnly: false) else { return nil }
        var v: Int32 = 0
        Self.query(db, "PRAGMA user_version") { v = sqlite3_column_int($0, 0) }
        if v != 0 && v != Self.version {
            sqlite3_close(db)
            for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + ext) }
            guard let fresh = Self.open(dbPath, readOnly: false) else { return nil }
            db = fresh
        }
        Self.exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS docs (
                id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, agent TEXT NOT NULL, sid TEXT NOT NULL,
                path TEXT NOT NULL, title TEXT NOT NULL, cwd TEXT, branch TEXT,
                mtime REAL NOT NULL, size INTEGER NOT NULL, indexed_at REAL NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0, machine TEXT, this_mac INTEGER);
            CREATE INDEX IF NOT EXISTS docs_mtime ON docs(mtime);
            CREATE VIRTUAL TABLE IF NOT EXISTS bodies USING fts5(body, tokenize = 'unicode61 remove_diacritics 2');
            PRAGMA user_version = \(Self.version);
            """)
        writer = db
        return db
    }

    private func pass() {
        guard let home, let db = openWriter() else { return }
        let t0 = Date().timeIntervalSince1970
        let (found, read) = discover(home)
        var known: [String: (id: Int64, mtime: Double, size: Int64, at: Double)] = [:]
        Self.query(db, "SELECT key, id, mtime, size, indexed_at FROM docs") { row in
            known[Self.text(row, 0)] = (sqlite3_column_int64(row, 1), sqlite3_column_double(row, 2), sqlite3_column_int64(row, 3), sqlite3_column_double(row, 4))
        }
        // Gone from disk (only for agents whose folder could be read just now).
        let keys = Set(found.map(\.key))
        let gone = known.filter { !keys.contains($0.key) && read.contains(String($0.key.prefix { $0 != ":" })) }
        if !gone.isEmpty {
            Self.exec(db, "BEGIN")
            for (_, k) in gone {
                Self.run(db, "DELETE FROM bodies WHERE rowid = ?", [k.id])
                Self.run(db, "DELETE FROM docs WHERE id = ?", [k.id])
            }
            Self.exec(db, "COMMIT")
        }
        let now = Date().timeIntervalSince1970
        let stale = found.filter { f in
            guard let k = known[f.key] else { return true }
            guard k.mtime != f.mtime || k.size != f.size else { return false }
            // Still being written: read it again at most every 15 minutes.
            return now - f.mtime > 120 || now - k.at > 900
        }.sorted { $0.mtime > $1.mtime }
        setState { $0.busy = true; $0.done = 0; $0.todo = stale.count; $0.docs = found.count }
        let titles = stale.contains { $0.agent == "codex" } ? Self.codexTitles(home) : [:]
        let sync = stale.isEmpty ? nil : Syncthing(home: SBPaths.home)
        for (i, f) in stale.enumerated() {
            autoreleasepool {
                let p = parse(f, codexTitles: titles)
                let ask = p?.firstAsk.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                let title = p?.title ?? ask.map { $0.count > 92 ? String($0.prefix(91)) + "…" : $0 }
                    ?? (p?.cwd).map { ($0 as NSString).lastPathComponent + " session" } ?? "Untitled"
                let hidden = p == nil || p!.text.isEmpty
                let machine = hidden ? nil : sync?.machine(f.agent == "grok" ? f.path + "/chat_history.jsonl" : f.path)
                store(db, f, id: known[f.key]?.id, title: title, parsed: p, hidden: hidden, machine: machine, at: now)
            }
            if i % 10 == 0 { setState { $0.done = i } }
        }
        setState {
            $0.busy = false; $0.done = stale.count
            $0.lastPassAt = Date().timeIntervalSince1970
            $0.lastPassSeconds = $0.lastPassAt - t0
        }
    }

    private func store(_ db: OpaquePointer, _ f: Found, id: Int64?, title: String, parsed p: Parsed?, hidden: Bool,
                       machine: (name: String, thisMac: Bool)?, at: Double) {
        let vals: [Any?] = [f.agent, f.sid, f.path, title, p?.cwd, p?.branch, f.mtime, f.size, at, hidden ? 1 : 0,
                            machine?.name, machine.map { $0.thisMac ? 1 : 0 }]
        Self.exec(db, "BEGIN")
        var rowid = id ?? 0
        if let id {
            Self.run(db, """
                UPDATE docs SET agent=?, sid=?, path=?, title=?, cwd=?, branch=?, mtime=?, size=?, indexed_at=?, hidden=?,
                machine=?, this_mac=? WHERE id=?
                """, vals + [id])
            Self.run(db, "DELETE FROM bodies WHERE rowid = ?", [id])
        } else {
            Self.run(db, """
                INSERT INTO docs (agent, sid, path, title, cwd, branch, mtime, size, indexed_at, hidden, machine, this_mac, key)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, vals + [f.key])
            rowid = sqlite3_last_insert_rowid(db)
        }
        if !hidden, let p {
            Self.run(db, "INSERT INTO bodies (rowid, body) VALUES (?, ?)", [rowid, p.text.body(title: p.title)])
        }
        Self.exec(db, "COMMIT")
    }

    private func setState(_ f: (inout Status) -> Void) {
        stateLock.lock(); f(&state); stateLock.unlock()
    }

    // MARK: Search

    /// The words as an index query: every word must be in the conversation, as the start of a
    /// word ("loc" finds "localization"). One-letter words must match whole.
    static func words(_ q: String) -> [String] {
        Array(q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(10))
    }

    static func matchExpression(_ q: String) -> String? {
        let words = words(q)
        guard !words.isEmpty else { return nil }
        return words.map { $0.count > 1 ? "\"\($0)\"*" : "\"\($0)\"" }.joined(separator: " ")
    }

    /// The words around the first place one of the words starts a word, with the words marked.
    /// (The index's own snippet() takes most of a second for a common word in 60 long
    /// conversations; this takes milliseconds.)
    static func snippet(_ body: String, words: [String]) -> String {
        let ns = body as NSString
        let isWord: (unichar) -> Bool = { c in
            guard let u = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u)
        }
        var first = NSNotFound
        for w in words {
            var from = 0
            while from < ns.length {
                let f = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                if f.location == NSNotFound { break }
                if f.location == 0 || !isWord(ns.character(at: f.location - 1)) {
                    first = min(first, f.location)
                    break
                }
                from = f.location + f.length
            }
        }
        let at = first == NSNotFound ? 0 : first
        var start = max(0, at - 70), end = min(ns.length, at + 170)
        // Not in the middle of a word.
        while start > 0, start > at - 90, isWord(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, end < at + 190, isWord(ns.character(at: end)) { end += 1 }
        var text = ns.substring(with: NSRange(location: start, length: end - start))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for w in words {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w) + "[\\p{L}\\p{N}]*"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{E000}$0\u{E001}")
        }
        return (start > 0 ? "…" : "") + text + (end < ns.length ? "…" : "")
    }

    private func openReader() -> OpaquePointer? {
        if let reader { return reader }
        guard FileManager.default.fileExists(atPath: dbPath), let db = Self.open(dbPath, readOnly: true) else { return nil }
        reader = db
        return db
    }

    private static let docColumns = "d.key, d.agent, d.sid, d.path, d.title, d.cwd, d.branch, d.mtime, d.machine, d.this_mac"

    private static func doc(_ row: OpaquePointer?, from i: Int32 = 0) -> Doc {
        func opt(_ c: Int32) -> String? { sqlite3_column_type(row, c) == SQLITE_NULL ? nil : text(row, c) }
        return Doc(key: text(row, i), agent: text(row, i + 1), sid: text(row, i + 2), path: text(row, i + 3), title: text(row, i + 4),
                   cwd: opt(i + 5), branch: opt(i + 6), mtime: sqlite3_column_double(row, i + 7), machine: opt(i + 8),
                   thisMac: sqlite3_column_type(row, i + 9) == SQLITE_NULL ? nil : sqlite3_column_int(row, i + 9) == 1)
    }

    /// Conversations that say every word of `q`. `listed`: the keys of sessions in Switchboard's
    /// list (they show with the list's rows; the rest show as other conversations).
    func search(_ q: String, listed: Set<String>, listLimit: Int = 30, otherLimit: Int = 25) -> Results {
        var r = Results()
        guard home != nil, let match = Self.matchExpression(q) else { return r }
        // Typing sends a search per pause: one that a newer search replaced stops early.
        stateLock.lock(); searchGen += 1; let gen = searchGen; stateLock.unlock()
        let replaced = { [self] () -> Bool in stateLock.lock(); defer { stateLock.unlock() }; return searchGen != gen }
        readLock.lock(); defer { readLock.unlock() }
        if replaced() { return r }
        guard let db = openReader() else { return r }
        // Newest first, all of them (thousands at most), then the words around the match for
        // the few that show.
        var listIDs: [Int64] = [], otherIDs: [Int64] = []
        Self.query(db, """
            SELECT d.id, d.key FROM bodies b JOIN docs d ON d.id = b.rowid
            WHERE bodies MATCH ? AND d.hidden = 0 ORDER BY d.mtime DESC
            """, [match]) { row in
            let id = sqlite3_column_int64(row, 0)
            if listed.contains(Self.text(row, 1)) {
                if listIDs.count < listLimit { listIDs.append(id) }
            } else {
                r.otherTotal += 1
                if otherIDs.count < otherLimit { otherIDs.append(id) }
            }
        }
        let ids = listIDs + otherIDs
        guard !ids.isEmpty, !replaced() else { return r }
        let words = Self.words(q)
        var hits: [Int64: Hit] = [:]
        Self.query(db, """
            SELECT b.rowid, b.body, \(Self.docColumns)
            FROM bodies b JOIN docs d ON d.id = b.rowid
            WHERE b.rowid IN (\(ids.map(String.init).joined(separator: ",")))
            """) { row in
            hits[sqlite3_column_int64(row, 0)] = Hit(doc: Self.doc(row, from: 2), snippet: Self.snippet(Self.text(row, 1), words: words))
        }
        r.inList = listIDs.compactMap { hits[$0] }
        r.other = otherIDs.compactMap { hits[$0] }
        return r
    }

    /// One conversation in the index.
    func doc(_ key: String) -> Doc? {
        readLock.lock(); defer { readLock.unlock() }
        guard let db = openReader() else { return nil }
        var out: Doc?
        Self.query(db, "SELECT \(Self.docColumns) FROM docs d WHERE d.key = ?", [key]) { out = Self.doc($0) }
        return out
    }

    /// When another Mac changed this conversation in the last 10 minutes, it may still run
    /// there: what to tell you before it resumes here.
    func otherMacWarning(_ d: Doc) -> String? {
        guard d.thisMac == false, let m = d.machine else { return nil }
        // The file now (the index may have read it a while ago).
        let file = d.agent == "grok" ? d.path + "/chat_history.jsonl" : d.path
        let age = Date().timeIntervalSince1970 - max(d.mtime, Self.attrs(file)?.mtime ?? 0)
        guard age < 600 else { return nil }
        let mins = max(1, Int(age / 60))
        return "“\(d.title)” changed on \(m) \(mins) min ago. It may still run there. If it runs on both Macs, both write to the same conversation and it splits in two."
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func open(_ path: String, readOnly: Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    static func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    static func text(_ row: OpaquePointer?, _ c: Int32) -> String {
        sqlite3_column_text(row, c).map { String(cString: $0) } ?? ""
    }

    static func run(_ db: OpaquePointer, _ sql: String, _ values: [Any?]) {
        query(db, sql, values) { _ in }
    }

    static func query(_ db: OpaquePointer, _ sql: String, _ values: [Any?] = [], row: (OpaquePointer?) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(st, n, s, -1, transient)
            case let d as Double: sqlite3_bind_double(st, n, d)
            case let x as Int64: sqlite3_bind_int64(st, n, x)
            case let x as Int: sqlite3_bind_int64(st, n, Int64(x))
            default: sqlite3_bind_null(st, n)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }
}
