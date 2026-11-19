import Foundation

/// A Claude conversation as the phone shows it: what you asked, what Claude answered,
/// and the tools it ran, read from the transcript file Claude writes
/// (~/.claude*/projects/<folder>/<session id>.jsonl).
///
/// A Reader reads the end of the file once, then only what Claude appends. Thinking,
/// sub-agents, hook output and request logs are left out. A tool's result arrives later
/// than its call: the call's item changes then (same id), and the phone replaces it.
enum SBConversation {
    struct Item {
        var id: String
        /// "you", "ai", "tool" or "note".
        var role: String
        var text: String = ""
        var at: Double = 0
        var tool: String?
        /// What the tool works on: the command, the file, the search.
        var detail: String?
        var output: String?
        var failed = false
        var done = false

        var json: [String: Any] {
            var o: [String: Any] = ["id": id, "r": role, "x": text, "at": Int(at)]
            if let tool { o["tn"] = tool }
            if let detail { o["td"] = detail }
            if let output { o["to"] = output }
            if role == "tool" {
                o["te"] = failed
                o["tok"] = done
            }
            return o
        }
    }

    final class Reader: @unchecked Sendable {
        let path: String
        private var offset: UInt64 = 0
        private var partial = Data()
        private(set) var items: [Item] = []
        private var index: [String: Int] = [:]

        /// How much of the file's end the first read takes. Transcripts hold large request
        /// logs, so a few MB still covers the recent conversation.
        static let firstRead: UInt64 = 6_000_000
        static let keep = 400

        init(path: String) { self.path = path }

        /// The first read: the last items of the conversation.
        func start() -> [Item] {
            let size = Self.size(path)
            offset = size > Self.firstRead ? size - Self.firstRead : 0
            let skipFirst = offset > 0      // the first line is cut in the middle
            _ = readNew(skippingFirstLine: skipFirst)
            return items
        }

        /// What changed since the last read: new items, and tool calls whose result came.
        func poll() -> [Item]? {
            let size = Self.size(path)
            if size < offset {
                // A new file under the same name (rare): start again.
                items = []
                index = [:]
                partial = Data()
                return start()
            }
            guard size > offset else { return [] }
            return readNew(skippingFirstLine: false)
        }

        static func size(_ path: String) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }

        private func readNew(skippingFirstLine: Bool) -> [Item] {
            guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? fh.close() }
            try? fh.seek(toOffset: offset)
            let data = fh.readDataToEndOfFile()
            offset += UInt64(data.count)
            var buf = partial
            buf.append(data)
            var changed: [String] = []
            var start = buf.startIndex
            var first = skippingFirstLine
            while let nl = buf[start...].firstIndex(of: 0x0A) {
                let line = buf[start..<nl]
                start = buf.index(after: nl)
                if first { first = false; continue }
                changed.append(contentsOf: parse(line))
            }
            partial = Data(buf[start...])
            trim()
            var seen = Set<String>()
            return changed.reversed().filter { seen.insert($0).inserted }.reversed().compactMap { id in index[id].map { items[$0] } }
        }

        private func trim() {
            guard items.count > Self.keep + 100 else { return }
            items.removeFirst(items.count - Self.keep)
            index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        }

        private func put(_ item: Item) {
            if let i = index[item.id] { items[i] = item } else { index[item.id] = items.count; items.append(item) }
        }

        /// One line of the transcript: the ids of the items it added or changed.
        private func parse(_ line: Data) -> [String] {
            // Request logs and bookkeeping lines start with their type; the conversation's
            // lines start with "parentUuid". Skip the rest without decoding them.
            guard line.starts(with: Data(#"{"parentUuid""#.utf8)) || line.starts(with: Data(#"{"type":"user""#.utf8))
                    || line.starts(with: Data(#"{"type":"assistant""#.utf8)),
                  let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
            if j["isSidechain"] as? Bool == true { return [] }
            let type = j["type"] as? String ?? ""
            let uuid = j["uuid"] as? String ?? UUID().uuidString
            let at = (j["timestamp"] as? String).flatMap(Self.date) ?? 0
            let content = (j["message"] as? [String: Any])?["content"]
            switch type {
            case "user":
                return user(j, uuid: uuid, at: at, content: content)
            case "assistant":
                guard let blocks = content as? [[String: Any]] else { return [] }
                var out: [String] = []
                for (n, b) in blocks.enumerated() {
                    switch b["type"] as? String {
                    case "text":
                        let text = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, text != "(no content)" else { continue }
                        let id = "\(uuid)#\(n)"
                        put(Item(id: id, role: "ai", text: text, at: at))
                        out.append(id)
                    case "tool_use":
                        guard let id = b["id"] as? String else { continue }
                        let name = b["name"] as? String ?? "Tool"
                        let input = b["input"] as? [String: Any] ?? [:]
                        var item = index[id].map { items[$0] } ?? Item(id: id, role: "tool", at: at)
                        item.tool = Self.toolName(name)
                        item.detail = Self.detail(name, input)
                        put(item)
                        out.append(id)
                    default:
                        continue
                    }
                }
                return out
            case "system":
                if j["subtype"] as? String == "compact_boundary" {
                    put(Item(id: uuid, role: "note", text: "Conversation compacted", at: at))
                    return [uuid]
                }
                return []
            default:
                return []
            }
        }

        private func user(_ j: [String: Any], uuid: String, at: Double, content: Any?) -> [String] {
            // The summary a compaction leaves for Claude is not something you said.
            if j["isCompactSummary"] as? Bool == true || j["isVisibleInTranscriptOnly"] as? Bool == true { return [] }
            if let text = content as? String {
                if j["isMeta"] as? Bool == true { return [] }
                if let kind = (j["origin"] as? [String: Any])?["kind"] as? String, kind != "human" { return [] }
                guard let shown = Self.typed(text) else { return [] }
                put(Item(id: uuid, role: shown.note ? "note" : "you", text: shown.text, at: at))
                return [uuid]
            }
            guard let blocks = content as? [[String: Any]] else { return [] }
            var out: [String] = []
            var texts: [String] = []
            var images = 0
            for b in blocks {
                switch b["type"] as? String {
                case "tool_result":
                    guard let id = b["tool_use_id"] as? String, var item = index[id].map({ items[$0] }) else { continue }
                    item.done = true
                    item.failed = b["is_error"] as? Bool == true
                    item.output = Self.resultText(b["content"])
                    put(item)
                    out.append(id)
                case "text":
                    if j["isMeta"] as? Bool == true { continue }
                    if let t = b["text"] as? String, let shown = Self.typed(t), !shown.note { texts.append(shown.text) }
                case "image":
                    if j["isMeta"] as? Bool != true { images += 1 }
                default:
                    continue
                }
            }
            if !texts.isEmpty || images > 0 {
                var text = texts.joined(separator: "\n\n")
                if images > 0 {
                    let mark = images == 1 ? "[Image]" : "[\(images) images]"
                    text = text.isEmpty ? mark : text + "\n" + mark
                }
                put(Item(id: uuid, role: "you", text: text, at: at))
                out.append(uuid)
            }
            return out
        }

        /// What you typed, as the phone shows it: slash commands as "/name args", the text
        /// without system reminders; nil for what the app or a hook added.
        static func typed(_ raw: String) -> (text: String, note: Bool)? {
            var t = raw
            if t.contains("<command-name>") {
                let name = between(t, "<command-name>", "</command-name>") ?? ""
                let args = between(t, "<command-args>", "</command-args>") ?? ""
                let line = (name.hasPrefix("/") ? name : "/" + name) + (args.isEmpty ? "" : " " + args)
                return line == "/" ? nil : (line, false)
            }
            for skip in ["<local-command-stdout>", "<local-command-stderr>", "<task-notification>", "<bash-stdout>", "<bash-stderr>", "Caveat: "] where t.hasPrefix(skip) {
                return nil
            }
            if t.hasPrefix("<bash-input>"), let cmd = between(t, "<bash-input>", "</bash-input>") { return ("! " + cmd, false) }
            while let r = t.range(of: "<system-reminder>"), let e = t.range(of: "</system-reminder>", range: r.upperBound..<t.endIndex) {
                t.removeSubrange(r.lowerBound..<e.upperBound)
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == "[Request interrupted by user]" || t == "[Request interrupted by user for tool use]" {
                return t.isEmpty ? nil : ("Stopped", true)
            }
            return (t, false)
        }

        static func between(_ s: String, _ a: String, _ b: String) -> String? {
            guard let r = s.range(of: a), let e = s.range(of: b, range: r.upperBound..<s.endIndex) else { return nil }
            return String(s[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func resultText(_ c: Any?) -> String {
            var s = ""
            if let str = c as? String { s = str }
            if let parts = c as? [[String: Any]] {
                s = parts.compactMap { p in p["type"] as? String == "text" ? p["text"] as? String : (p["type"] as? String == "image" ? "[Image]" : nil) }
                    .joined(separator: "\n")
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.count > 1500 ? String(s.prefix(1500)) + "\n…" : s
        }

        /// "Read", "Bash", or for an MCP tool its own name ("list_issues").
        static func toolName(_ name: String) -> String {
            guard name.hasPrefix("mcp__") else { return name }
            return name.split(separator: "_", omittingEmptySubsequences: true).last.map(String.init) ?? name
        }

        static func detail(_ name: String, _ input: [String: Any]) -> String? {
            func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            func short(_ x: String?, _ n: Int = 240) -> String? {
                guard let x else { return nil }
                let one = x.split(whereSeparator: \.isNewline).first.map(String.init) ?? x
                let t = one.trimmingCharacters(in: .whitespaces)
                return t.count > n ? String(t.prefix(n)) + "…" : t
            }
            switch name {
            case "Bash": return short(s("command"))
            case "Read", "Write", "Edit", "MultiEdit": return s("file_path").map(SBPaths.tilde)
            case "NotebookEdit": return s("notebook_path").map(SBPaths.tilde)
            case "Grep": return short([s("pattern"), s("path").map(SBPaths.tilde)].compactMap { $0 }.joined(separator: "  in "))
            case "Glob": return short(s("pattern"))
            case "WebFetch": return short(s("url"))
            case "WebSearch": return short(s("query"))
            case "Task", "Agent": return short(s("description") ?? s("prompt"))
            case "Skill": return short(s("skill"))
            case "ToolSearch": return short(s("query"))
            case "TodoWrite": return (input["todos"] as? [Any]).map { "\($0.count) to-dos" }
            case "AskUserQuestion":
                let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
                return short(q)
            default:
                // The first text argument says most (an MCP tool's query, title or id).
                for k in ["query", "title", "url", "path", "id", "name", "description"] { if let v = s(k) { return short(v) } }
                return input.values.compactMap { $0 as? String }.first.flatMap { short($0) }
            }
        }

        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        static func date(_ s: String) -> Double? { iso.date(from: s)?.timeIntervalSince1970 }
    }
}
