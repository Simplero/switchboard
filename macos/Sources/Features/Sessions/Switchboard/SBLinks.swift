import Foundation
import SQLite3

/// A page a session gave you: something it published (a claude.ai artifact, a Simplero
/// Doc) or a page on the dev server. The panel shows these by title, not by URL.
struct SBLink: Codable, Equatable {
    /// "dev", "doc" or "artifact".
    var kind: String
    var url: String
    /// The page's own title (nil until known; the panel then shows a label made from the URL).
    var title: String?
    /// Artifact: the login that published it (the Arc Space it opens in).
    var login: String?
    /// When the session last gave it.
    var at: Double
}

/// What a session works on, and what is still open in it: a model's reading of the
/// conversation, so you can come back to a session you forgot.
struct SBBrief: Codable, Equatable {
    struct Item: Codable, Equatable {
        /// "you" (waits for you) or "agent" (work not done yet).
        var who: String?
        var text: String
    }
    /// One thing the session works on (a session often does two or three).
    struct Topic: Codable, Equatable {
        var title: String
        /// "working", "you" (waits for Calvin), "done" or "later".
        var state: String
        var done: [String]
        var open: [Item]
        /// Up to two links to check this topic with (a Doc, a PR, a dev page).
        var links: [String]
    }
    var goal: String
    var open: [Item]
    /// Where the session stands now, in one sentence.
    var now: String? = nil
    /// The one thing to check next, and where.
    var check: String? = nil
    var checkURL: String? = nil
    var topics: [Topic]? = nil
    /// What was put off for later.
    var later: [String]? = nil
    /// The latest messages moved to a topic its Doc does not cover.
    var drift: Bool? = nil
    /// The transcript size it read, and when.
    var size: Int
    var at: Double
}

/// Finds the links in each session's transcript (once per new byte) and reads the
/// conversation for the brief.
enum SBLinks {
    static let cachePath = SBPaths.data + "/links-v1.json"
    static let briefsPath = SBPaths.data + "/briefs-v1.json"
    /// simplero-doc writes one line per published Doc, with the session that published it.
    static let docsRegistry = SBPaths.home + "/.config/simplero-doc/docs.jsonl"

    private struct Index: Codable {
        var off: Int = 0
        /// Artifact tool calls waiting for their result: tool use id → title / file.
        var pend: [String: [String: String]] = [:]
        var links: [SBLink] = []
        var seen: Double = 0
    }

    private static let lock = NSLock()
    private static var cache: [String: Index]?
    private static var chromeAt: Double = 0
    private static var chrome: [String: String] = [:]
    /// For checks: how many dev page titles the last read of Chrome's history found.
    static var chromeCount: Int { lock.lock(); defer { lock.unlock() }; return chrome.count }

    // MARK: Links

    /// The links of each session, newest first.
    static func index(_ sessions: [(sid: String, loginDir: String?)]) -> [String: [SBLink]] {
        lock.lock()
        defer { lock.unlock() }
        var all = cache ?? ((try? JSONDecoder().decode([String: Index].self,
                                                       from: FileManager.default.contents(atPath: cachePath) ?? Data())) ?? [:])
        let docs = Docs.read()
        let now = Date().timeIntervalSince1970
        for (sid, loginDir) in sessions {
            var ix = all[sid] ?? Index()
            ix.seen = now
            if let f = SBBackground.transcriptPath(sid) {
                let size = fileSize(f)
                if size < ix.off { ix = Index(); ix.seen = now }   // a rewritten file: read it again
                if size > ix.off { read(f, into: &ix, login: loginDir) }
            }
            for d in docs.bySession[sid] ?? [] {
                add(&ix, SBLink(kind: "doc", url: d.share, title: d.title, login: nil, at: d.at))
            }
            all[sid] = ix
        }
        // Titles: Docs from simplero-doc's records, artifacts from any session that published
        // them, dev pages from Chrome's history (once you opened them there).
        var artifactInfo: [String: (title: String?, login: String?)] = [:]
        for ix in all.values {
            for l in ix.links where l.kind == "artifact" && l.title != nil {
                if artifactInfo[l.url] == nil { artifactInfo[l.url] = (l.title, l.login) }
            }
        }
        var wantChrome = false
        for s in sessions {
            let untitled = (all[s.sid]?.links ?? []).contains { (l: SBLink) -> Bool in l.kind == "dev" && l.title == nil }
            if untitled { wantChrome = true; break }
        }
        // Chrome's history is read again at most once a minute; the last reading stays in use.
        if wantChrome && now - chromeAt > 60 {
            chromeAt = now
            chrome = chromeTitles()
        }
        var out: [String: [SBLink]] = [:]
        for (sid, _) in sessions {
            guard var ix = all[sid] else { continue }
            var merged: [SBLink] = []
            for var l in ix.links {
                switch l.kind {
                case "doc":
                    if let d = docs.byURL[l.url] { l.url = d.share; l.title = d.title }
                case "artifact":
                    if let i = artifactInfo[l.url] { l.title = l.title ?? i.title; l.login = l.login ?? i.login }
                default:
                    if l.title == nil, let t = lookup(l.url, in: chrome) { l.title = t }
                }
                if let i = merged.firstIndex(where: { $0.url == l.url }) {
                    merged[i].at = max(merged[i].at, l.at)
                    merged[i].title = merged[i].title ?? l.title
                } else {
                    merged.append(l)
                }
            }
            ix.links = merged
            all[sid] = ix
            out[sid] = merged.sorted { $0.at > $1.at }
        }
        // Forget sessions not seen for 30 days.
        all = all.filter { now - $0.value.seen < 30 * 86400 }
        cache = all
        if let d = try? JSONEncoder().encode(all) { SBFiles.writeAtomic(d, cachePath) }
        return out
    }

    private static func fileSize(_ f: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Each whole line from `ix.off` on. A line still being written waits for the next pass.
    private static func read(_ f: String, into ix: inout Index, login: String?) {
        guard let fh = FileHandle(forReadingAtPath: f) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(ix.off))
        var carry = Data()
        var off = ix.off
        while true {
            let chunk = fh.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                let line = carry[start..<nl]
                off += line.count + 1
                if !line.isEmpty { process(String(decoding: line, as: UTF8.self), &ix, login: login) }
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
        }
        ix.off = off
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func process(_ line: String, _ ix: inout Index, login: String?) {
        let assistant = line.contains("\"type\":\"assistant\"")
        let user = !assistant && line.contains("\"type\":\"user\"")
        guard assistant || user else { return }
        // Tool results are big and many: only an Artifact call's result matters.
        if user && line.contains("\"tool_result\"") && (ix.pend.isEmpty || !line.contains("claude.ai/")) { return }
        if line.contains("\"isMeta\":true") || line.contains("\"isCompactSummary\":true") { return }
        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let msg = j["message"] as? [String: Any] else { return }
        let at = (j["timestamp"] as? String).flatMap { iso.date(from: $0)?.timeIntervalSince1970 } ?? Date().timeIntervalSince1970
        if let text = msg["content"] as? String {
            if user { scan(text, &ix, at: at) }
            return
        }
        guard let parts = msg["content"] as? [[String: Any]] else { return }
        for p in parts {
            switch p["type"] as? String {
            case "text":
                if let t = p["text"] as? String { scan(t, &ix, at: at) }
            case "tool_use" where p["name"] as? String == "Artifact":
                guard let id = p["id"] as? String, let input = p["input"] as? [String: Any] else { continue }
                let action = input["action"] as? String ?? "publish"
                guard action == "publish", input["asset"] as? Bool != true else { continue }
                var info: [String: String] = [:]
                if let t = input["title"] as? String { info["t"] = t }
                if let f = input["file_path"] as? String { info["f"] = f }
                ix.pend[id] = info
            case "tool_result":
                guard let id = p["tool_use_id"] as? String, let info = ix.pend.removeValue(forKey: id) else { continue }
                let c = p["content"]
                let text = (c as? String) ?? ((c as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "")
                guard let url = first(publishedRE, in: text) else { continue }
                let title = info["t"].map(clean) ?? info["f"].flatMap { htmlTitle($0) ?? fileTitle($0) }
                add(&ix, SBLink(kind: "artifact", url: url, title: title, login: login, at: at))
            default:
                break
            }
        }
    }

    // "Published <file> at <url>", "Updated the Artifact at <url>", "Created a new Artifact at <url>".
    private static let publishedRE = try! NSRegularExpression(
        pattern: #"^(?:Published .+? at|Updated the Artifact at|Created a new Artifact at) (https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9-]{10,})"#)
    private static let devRE = try! NSRegularExpression(
        pattern: #"https?://[A-Za-z0-9.-]+\.(?:test|internal)(?::\d{2,5})?(?:[/?#][^\s"'<>`\]\)|]*)?"#)
    private static let docRE = try! NSRegularExpression(
        pattern: #"https://(?:doc\.simplero\.me/[A-Za-z0-9]{8,}|[a-z0-9-]+\.simplero\.com/admin/docs/\d+)"#)
    private static let artifactRE = try! NSRegularExpression(pattern: #"https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9-]{10,}"#)
    private static let reminderRE = try! NSRegularExpression(pattern: #"<system-reminder>[\s\S]*?</system-reminder>"#)
    /// Dev URLs that are not pages to look at.
    private static let notAPage = try! NSRegularExpression(
        pattern: #"/(?:api|rails|assets|vite[^/]*|packs|cable)/|\.(?:png|jpe?g|gif|svg|ico|css|js|mjs|map|json|woff2?|mp4|webm)(?:[?#]|$)"#,
        options: .caseInsensitive)

    private static func first(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func all(_ re: NSRegularExpression, in s: String) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func scan(_ raw: String, _ ix: inout Index, at: Double) {
        guard raw.contains("://") else { return }
        let text = raw.contains("<system-reminder>")
            ? reminderRE.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "") : raw
        for var u in all(devRE, in: text) {
            while let c = u.last, ".,;:!?*'\"".contains(c) { u.removeLast() }
            if notAPage.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)) != nil { continue }
            add(&ix, SBLink(kind: "dev", url: u, title: nil, login: nil, at: at))
        }
        for u in all(docRE, in: text) { add(&ix, SBLink(kind: "doc", url: u, title: nil, login: nil, at: at)) }
        for u in all(artifactRE, in: text) { add(&ix, SBLink(kind: "artifact", url: u, title: nil, login: nil, at: at)) }
    }

    private static func add(_ ix: inout Index, _ l: SBLink) {
        if let i = ix.links.firstIndex(where: { $0.url == l.url }) {
            ix.links[i].at = max(ix.links[i].at, l.at)
            if let t = l.title { ix.links[i].title = t }
            if ix.links[i].login == nil { ix.links[i].login = l.login }
            return
        }
        ix.links.append(l)
        // Keep the newest 40 of each kind.
        let same = ix.links.filter { $0.kind == l.kind }
        if same.count > 40, let oldest = same.min(by: { $0.at < $1.at }) {
            ix.links.removeAll { $0.url == oldest.url }
        }
    }

    /// The <title> of a page file, if it still exists.
    private static func htmlTitle(_ path: String) -> String? {
        guard path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm"),
              let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let head = String(decoding: fh.readData(ofLength: 16_384), as: UTF8.self)
        guard let r = head.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(head[r])
        guard let open = tag.firstIndex(of: ">"), let close = tag.range(of: "</", options: .backwards) else { return nil }
        let t = clean(String(tag[tag.index(after: open)..<close.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'"))
        return t.isEmpty ? nil : t
    }

    /// A name from the published file when the file is gone: ".../welcome-page.html" →
    /// "Welcome page"; "index.html" takes its folder's name.
    private static func fileTitle(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        var base = url.deletingPathExtension().lastPathComponent
        if ["index", "main", "page", "canvas"].contains(base.lowercased()) {
            base = url.deletingLastPathComponent().lastPathComponent
            if base == "project" { base = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
        }
        let words = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard !words.isEmpty, words != "scratchpad" else { return nil }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A page title without the product name: "Inputs - Calvin Test 3's Simplero" → "Inputs".
    static func clean(_ t: String) -> String {
        var s = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = s.replacingOccurrences(of: #"\s+[-–—|·•:]\s+[^-–—|·•]*\bSimplero\b[^-–—|·•]*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[^-–—|·•]*\bSimplero\b\s*[-–—|·•:]\s+"#, with: "", options: .regularExpression)
        return s == "Simplero" ? "" : s
    }

    /// A short name made from a dev URL, until Chrome knows the page's title:
    /// "/admin/surveys/6984/edit" → "Surveys 6984 edit".
    static func label(_ l: SBLink) -> String {
        if let t = l.title, !t.isEmpty { return t }
        guard let c = URLComponents(string: l.url) else { return l.url }
        switch l.kind {
        case "doc":
            if let id = c.path.split(separator: "/").last, c.path.contains("/admin/docs/") { return "Doc \(id)" }
            return "Simplero Doc"
        case "artifact":
            return "Artifact"
        default:
            var parts = c.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            if parts.first == "admin" && parts.count > 1 { parts.removeFirst() }
            let words = parts.map { $0.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") }
            let s = words.joined(separator: " ")
            if s.isEmpty { return (c.host ?? l.url).components(separatedBy: ".").first ?? l.url }
            return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    // MARK: Simplero Docs (simplero-doc's records)

    private struct Docs {
        struct Doc { var share: String; var title: String?; var at: Double }
        var byURL: [String: Doc] = [:]
        var bySession: [String: [Doc]] = [:]

        static func read() -> Docs {
            var out = Docs()
            guard let text = try? String(contentsOfFile: docsRegistry, encoding: .utf8) else { return out }
            var byID: [String: (doc: Doc, editor: String?, sid: String?)] = [:]
            for line in text.split(separator: "\n") {
                guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let share = j["share"] as? String else { continue }
                let id = (j["doc_id"] as? NSNumber)?.stringValue ?? share
                let title = (j["title"] as? String).map(clean)
                let at = (j["at"] as? NSNumber)?.doubleValue ?? 0
                let first = byID[id]
                byID[id] = (Doc(share: share, title: title ?? first?.doc.title, at: at),
                            (j["editor"] as? String) ?? first?.editor, first?.sid ?? (j["session_id"] as? String))
            }
            for (_, d) in byID {
                out.byURL[d.doc.share] = d.doc
                if let e = d.editor { out.byURL[e] = d.doc }
                if let sid = d.sid { out.bySession[sid, default: []].append(d.doc) }
            }
            return out
        }
    }

    // MARK: Dev page titles (Chrome's history)

    /// Titles of dev pages you opened in Chrome: URL → title, newest visit first.
    private static func chromeTitles() -> [String: String] {
        let root = SBPaths.home + "/Library/Application Support/Google/Chrome"
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        var out: [String: String] = [:]
        for p in profiles {
            let src = root + "/" + p + "/History"
            guard FileManager.default.fileExists(atPath: src) else { continue }
            // Chrome keeps the file locked: read a copy.
            let tmp = NSTemporaryDirectory() + "switchboard-chrome-history-\(getpid()).db"
            try? FileManager.default.removeItem(atPath: tmp)
            guard (try? FileManager.default.copyItem(atPath: src, toPath: tmp)) != nil else { continue }
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); continue }
            defer { sqlite3_close(db) }
            var st: OpaquePointer?
            let q = "SELECT url, title FROM urls WHERE (url LIKE '%.test%' OR url LIKE '%.internal%') AND title != '' ORDER BY last_visit_time DESC LIMIT 20000"
            guard sqlite3_prepare_v2(db, q, -1, &st, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW {
                guard let u = sqlite3_column_text(st, 0), let t = sqlite3_column_text(st, 1) else { continue }
                let url = String(cString: u), title = clean(String(cString: t))
                // Chrome shows the address when a page has no title (or did not load), and a
                // page that sent you to the login says nothing about the page you wanted.
                let lower = title.lowercased()
                guard !title.isEmpty, !lower.hasPrefix("http"), !lower.hasSuffix(".test"), !lower.contains(".test/"),
                      !lower.contains(".test:"), !lower.hasSuffix(".internal"),
                      !["log in", "login", "sign in", "sign in to simplero"].contains(lower) else { continue }
                for k in keys(url) where out[k] == nil { out[k] = title }
            }
        }
        return out
    }

    /// The URL, then without its #fragment, then without its ?query (a page Chrome saw
    /// with other parameters still has the same title).
    private static func keys(_ url: String) -> [String] {
        var out = [url]
        let noFrag = url.components(separatedBy: "#")[0]
        out.append("~" + noFrag)
        out.append("~~" + noFrag.components(separatedBy: "?")[0])
        return out
    }

    private static func lookup(_ url: String, in map: [String: String]) -> String? {
        let k = keys(url)
        return map[k[0]] ?? map[k[1]] ?? map[k[2]]
    }

    // MARK: Brief (what the session works on, what is still open)

    static func loadBriefs() -> [String: SBBrief] {
        (try? JSONDecoder().decode([String: SBBrief].self, from: FileManager.default.contents(atPath: briefsPath) ?? Data())) ?? [:]
    }

    static func saveBriefs(_ b: [String: SBBrief]) {
        if let d = try? JSONEncoder().encode(b) { SBFiles.writeAtomic(d, briefsPath) }
    }

    static func transcriptSize(_ sid: String) -> Int? {
        SBBackground.transcriptPath(sid).map(fileSize)
    }

    static let briefPrompt = """
    You read a log of a coding-agent session: Calvin's messages and the agent's replies (tool
    calls are left out). Calvin runs many sessions at once. He starts something, forgets it, and
    later cannot remember what the session was about or what was never finished. Help him remember.

    Return ONLY a JSON object, no prose:
    {"goal": "...", "open": [{"who": "you", "text": "..."}, {"who": "agent", "text": "..."}],
     "now": "...", "check": {"text": "...", "url": "..."},
     "topics": [{"title": "...", "state": "working", "done": ["..."], "open": [{"who": "you", "text": "..."}], "links": ["https://..."]}],
     "later": ["..."], "drift": false}

    "goal": what this session works on now, max 12 words, plain words. Say the thing itself
      ("Show doc and dev links in the Switchboard panel"), not "Calvin wants…".
    "open": what was raised in this session and is not finished, most important first, max 5,
      each max 14 words.
      who "you": it waits for Calvin: a question the agent asked him, a choice, something to look
        at or try, a step only he can do.
      who "agent": work Calvin asked for or the agent promised that is not done, was put off for
        later, or was dropped without a word.
      Leave out what is done, what Calvin rejected or said to skip, and routine steps agents do by
      themselves (tests, CI, screenshots) unless they are stuck. [] when nothing is open.
    "now": where the session stands right now, one sentence, max 16 words ("PR #431 is merged; the
      deploy is running"). For Calvin, who asks "status?" a lot.
    "check": the one thing Calvin should look at next, max 12 words, with the link to look at it
      (a URL from the log: a Doc, a PR, a dev page); null when nothing waits for him.
    "topics": the separate things this session works on, 1 to 4, in the order they came up. Each:
      "title" max 8 words; "state": "working" (the agent is on it), "you" (it waits for Calvin),
      "done" or "later" (put off); "done": finished parts, max 4, each max 10 words; "open": what
      is not finished, as in "open" above, max 4; "links": at most 2 URLs from the log that matter
      for checking it (a Simplero Doc first, then a PR, then a dev page), [] when none.
    "later": what Calvin or the agent put off for later ("after the deploy", "next week"), max 4,
      each max 12 words; [] when none.
    "drift": true when the latest messages work on something none of the earlier topics covers,
      so it may need its own Doc or session; else false.
    Write each item like a task title: short and plain, no "I", "me", "my" or "your", no markdown.
    If the log ends with a new message from Calvin, the agent has not answered it yet: it is open
    work for the agent, not for him.

    Log:

    """

    /// Read the conversation and ask the model. nil when it did not answer.
    static func brief(_ sid: String) -> SBBrief? {
        guard let f = SBBackground.transcriptPath(sid) else { return nil }
        let size = fileSize(f)
        guard let log = condensed(f), !log.isEmpty else { return nil }
        guard let out = SBBackground.ask("sonnet", briefPrompt + log, timeout: 180),
              let open = out.firstIndex(of: "{"), let close = out.lastIndex(of: "}"), open < close,
              let j = try? JSONSerialization.jsonObject(with: Data(out[open...close].utf8)) as? [String: Any] else { return nil }
        let goal = (j["goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let items: [SBBrief.Item] = ((j["open"] as? [Any]) ?? []).compactMap { x in
            if let s = x as? String { return SBBrief.Item(who: nil, text: s) }
            guard let d = x as? [String: Any], let t = d["text"] as? String, !t.isEmpty else { return nil }
            return SBBrief.Item(who: d["who"] as? String, text: t)
        }
        func item(_ x: Any) -> SBBrief.Item? {
            if let s = x as? String { return s.isEmpty ? nil : SBBrief.Item(who: nil, text: s) }
            guard let d = x as? [String: Any], let t = d["text"] as? String, !t.isEmpty else { return nil }
            return SBBrief.Item(who: d["who"] as? String, text: t)
        }
        let strings: (Any?) -> [String] = { ($0 as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty } }
        let topics: [SBBrief.Topic] = ((j["topics"] as? [Any]) ?? []).compactMap { x in
            guard let d = x as? [String: Any], let title = d["title"] as? String, !title.isEmpty else { return nil }
            let links = strings(d["links"]).filter { $0.hasPrefix("http") }
            return SBBrief.Topic(title: title, state: d["state"] as? String ?? "working", done: Array(strings(d["done"]).prefix(4)),
                                 open: Array(((d["open"] as? [Any]) ?? []).compactMap(item).prefix(4)), links: Array(links.prefix(2)))
        }
        let check = j["check"] as? [String: Any]
        var b = SBBrief(goal: goal, open: Array(items.prefix(5)), size: size, at: Date().timeIntervalSince1970)
        b.now = (j["now"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        b.check = (check?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        b.checkURL = (check?["url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
        b.topics = Array(topics.prefix(4))
        b.later = Array(strings(j["later"]).prefix(4))
        b.drift = j["drift"] as? Bool
        return b
    }

    /// The conversation as plain text: the first ask, the summary Claude wrote when it
    /// compacted, and as many of the latest messages as fit.
    static func condensed(_ path: String, budget: Int = 40_000) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var msgs: [(who: String, text: String)] = []
        var summary: String?
        var carry = Data()
        func handle(_ line: String) {
            let assistant = line.contains("\"type\":\"assistant\"")
            guard assistant || line.contains("\"type\":\"user\"") else { return }
            if !assistant && line.contains("\"tool_result\"") { return }
            if assistant && !line.contains("\"type\":\"text\"") { return }
            if line.contains("\"isMeta\":true") { return }
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = j["message"] as? [String: Any] else { return }
            var text = ""
            if let s = msg["content"] as? String { text = s }
            else if let parts = msg["content"] as? [[String: Any]] {
                text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            if j["isCompactSummary"] as? Bool == true {
                summary = reminderRE.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                    .replacingOccurrences(of: "<artifact-content-authored-by-others/>", with: "")
                return
            }
            if !assistant {
                if text.contains("<system-reminder>") {
                    text = reminderRE.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || t.hasPrefix("<command-") || t.hasPrefix("<local-command") || t.hasPrefix("Caveat:")
                    || t.hasPrefix("[Request interrupted") { return }
                text = t
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let who = assistant ? "Agent" : "Calvin"
            if let last = msgs.last, last.who == who, assistant { msgs[msgs.count - 1].text += "\n" + text } else { msgs.append((who, text)) }
        }
        while true {
            let chunk = fh.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            carry.append(chunk)
            var start = carry.startIndex
            while let nl = carry[start...].firstIndex(of: 0x0A) {
                if nl > start { handle(String(decoding: carry[start..<nl], as: UTF8.self)) }
                start = carry.index(after: nl)
            }
            carry = Data(carry[start...])
        }
        if !carry.isEmpty { handle(String(decoding: carry, as: UTF8.self)) }
        guard !msgs.isEmpty else { return nil }
        func cut(_ s: String, _ n: Int) -> String {
            guard s.count > n else { return s }
            return String(s.prefix(n * 2 / 5)) + " […] " + String(s.suffix(n * 3 / 5))
        }
        let lines = msgs.map { "\($0.who): " + cut($0.text, $0.who == "Calvin" ? 2000 : 1500) }
        var tail: [String] = []
        var used = 0
        for l in lines.reversed() {
            if used + l.count > budget { break }
            tail.insert(l, at: 0)
            used += l.count + 2
        }
        var head: [String] = []
        if let s = summary { head.append("Summary of the earlier part (written when the log was compacted):\n" + cut(s, 6000)) }
        if tail.count < lines.count, let firstAsk = lines.first(where: { $0.hasPrefix("Calvin: ") }) {
            head.append("First message:\n" + firstAsk)
            head.append("[…]")
        }
        return (head + tail).joined(separator: "\n\n")
    }
}
