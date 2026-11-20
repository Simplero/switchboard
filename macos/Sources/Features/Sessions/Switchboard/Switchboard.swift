import AppKit
import Foundation

/// The session tracker, inside the app (it replaces the Python session helper).
///
/// - Finds every coding agent (Claude, Codex, OpenCode, Grok) in the app's terminals
///   every 1.5 s, and keeps a registry of sessions on disk, open or closed.
/// - Says what each session needs from you (screen state, and Haiku's reading of
///   the end of the terminal), its login, folder, branch and plan usage.
/// - Runs the sidebar's actions: open, new, new shell, done, close, park, switch
///   login, resume by id, rename, labels, classes, reply, restart for an update.
/// - Feeds the sidebar and the panel (two web pages shipped in the app).
///
/// Everything here runs on the main thread, so the registry has one writer and the
/// scan and the actions cannot race. Slow reads run in the background (SBBackground).
@MainActor
final class Switchboard {
    static let shared = Switchboard()

    private(set) var reg = SBRegistry()
    private var summaries: [String: SBSummary] = [:]
    private var summaryOrder: [String] = []
    private var pendingSummaries = Set<String>()
    /// Screens Haiku did not answer for, and when: tried again after a minute, not every scan.
    private var failedSummaries: [String: Double] = [:]
    private var usage: [String: Any] = [:]
    private var usageAt: Double = 0
    private var artifacts: [String: [String]] = [:]
    /// Terminals opened for an agent, and when: an agent starts in a plain shell, so
    /// these are not taken for shell sessions during their first 20 s.
    private var recentNew: [String: Double] = [:]
    private var scanning = false
    private var started = false
    private var timer: Timer?
    private var slowTimer: Timer?
    private var lastPushed: Data?
    private var saveScheduled = false
    private(set) var loaded = false
    /// False when another program holds the session list: then nothing is saved.
    private var writable = false
    /// Sessions in the middle of a login switch (no second switch or open meanwhile).
    private var switching = Set<String>()
    private var switchOpening = false
    private var elsewhereAt: Double = 0
    private var claudeAppAt: Double = 0
    /// Claude app sessions removed from the list here: not listed again while the app keeps them.
    private var removedFromApp = Set(UserDefaults.standard.stringArray(forKey: "sessions.claudeApp.removed") ?? [])
    /// Sessions that ran in another terminal at the last look (shown as "elsewhere", not as closed).
    private var elsewhereKeys = Set<String>()
    /// Pages each open session gave you (docs, artifacts, dev pages), by conversation id.
    private var links: [String: [SBLink]] = [:]
    private var linksAt: Double = 0
    private var linksRunning = false
    /// What each session works on and what is still open in it, by conversation id.
    private var briefs: [String: SBBrief] = [:]
    private var pendingBriefs = Set<String>()
    private var failedBriefs: [String: Double] = [:]
    private var transcriptSizes: [String: Int] = [:]
    /// Names given in the new-session form, by terminal: the session takes the name when the
    /// scan first sees its agent.
    private var pendingNames: [String: (name: String, at: Double)] = [:]
    /// Since when each open session needs you (by key): the sidebar lists the longest-waiting first.
    private var needsSince: [String: Double] = [:]
    static let needsStates: Set<String> = ["permission", "question", "review", "heads_up"]

    static let scanEvery = 1.5
    /// How often to look for sessions in other terminals (cmux, Terminal…).
    static let elsewhereEvery = 5.0
    /// How often to read the Claude app's session list.
    static let claudeAppEvery = 30.0
    static let defaultFolder = "~/Simplero"
    private let summariesOn = ProcessInfo.processInfo.environment["SWITCHBOARD_NO_SUMMARIES"] == nil

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        let real = !SBPaths.overridden
        // Changes from the last second must not be lost when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Switchboard.shared.saveNow(wait: true) }
        }
        Task.detached(priority: .userInitiated) {
            // The old Python helper must not write the registry any more (a test copy has its
            // own data folder and leaves the real one alone). Then hold the helper's lock, so
            // a helper started again later (cmux restores it) exits at once.
            if real { SBBackground.stopOldHelper() }
            let locked = SBFiles.takeLock()
            let reg = SBRegistry.load()
            let summaries = Switchboard.readSummaries()
            SessionsAttachments.prune()
            await MainActor.run { Switchboard.shared.finishStart(reg, summaries: summaries, writable: locked) }
        }
    }

    private func finishStart(_ loadedReg: SBRegistry, summaries cache: [String: SBSummary], writable: Bool) {
        reg = loadedReg
        summaries = cache
        summaryOrder = Array(cache.keys)
        self.writable = writable
        // Sessions that ran in cmux are not shown as running here: they show as
        // closed and reopen here (cmux is no longer read).
        for (k, e) in reg.sessions where e.isOpen && e.backend != "ghostty" {
            var x = e
            x.open = false
            x.closed_at = e.last_seen ?? now
            x.closed_reason = "cmux"
            x.screen = nil
            x.state = stateOf(x)
            reg.sessions[k] = x
        }
        // After a restart for an update: the saved list is the signal (the flag alone could be
        // used up by a launch that died before it restored anything).
        let flagged = UserDefaults.standard.bool(forKey: "sessions.restoreAfterRestart")
        let saved = (SBFiles.readJSON(SBPaths.restart) as? [String: Any]).map { now - (($0["at"] as? NSNumber)?.doubleValue ?? 0) <= 600 } ?? false
        let restoring = flagged || saved
        if restoring { markStaleClosed(reason: "restart") }
        // The first look at other terminals waits 20 s: after an update the old app's terminals
        // are still being handed over, and their sessions must not count as running elsewhere.
        elsewhereAt = now + 15
        briefs = SBLinks.loadBriefs()
        loaded = true
        seedPins()
        save()
        timer = Timer.scheduledTimer(withTimeInterval: Self.scanEvery, repeats: true) { _ in
            Task { @MainActor in await Switchboard.shared.scan() }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Switchboard.shared.slowWork() }
        }
        slowWork()
        if !writable {
            SessionsStore.shared.showFailure("Another program keeps the session list (\(SBPaths.registry)): another Switchboard, or the old session helper. This window shows your sessions but does not save changes to the list.")
        }
        Task { @MainActor in
            // The app opens one plain shell at launch. After a restart the sessions come
            // back as tabs of the one window, so that untouched one closes.
            let initial = NSApp.windows.filter { $0.windowController is BaseTerminalController }
            // Terminals the app before an update handed over: their programs still run.
            var handedOver = Set<String>()
            if let got = await Task.detached(priority: .userInitiated, operation: { SBHandoff.receive() }).value {
                handedOver = SBHandoff.adopt(got)
                SBHandoff.finish(got)
            }
            await scan()
            if restoring || !handedOver.isEmpty {
                let (ok, msg) = await restoreAfterRestart(skipping: handedOver)
                UserDefaults.standard.set(false, forKey: "sessions.restoreAfterRestart")
                if !ok { SessionsStore.shared.showFailure(msg) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                SessionsStore.closeUntouched(initial)
            }
        }
    }

    // MARK: Persistence

    private func save() {
        guard loaded, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                self.saveNow()
            }
        }
    }

    /// Save the registry. With `wait`, on return it is on disk (or the result says it is not).
    @discardableResult
    func saveNow(wait: Bool = false) -> Bool {
        guard loaded, writable, let data = reg.encoded() else { return false }
        if wait { return SBFiles.queue.sync { SBFiles.writeAtomic(data, SBPaths.registry) } }
        SBFiles.queue.async { SBFiles.writeAtomic(data, SBPaths.registry) }
        return true
    }

    nonisolated static func readSummaries() -> [String: SBSummary] {
        guard let d = FileManager.default.contents(atPath: SBPaths.summaries),
              let top = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        let decoder = JSONDecoder()
        var out: [String: SBSummary] = [:]
        for (k, v) in top {
            if let vd = try? JSONSerialization.data(withJSONObject: v), let s = try? decoder.decode(SBSummary.self, from: vd) { out[k] = s }
        }
        return out
    }

    private func saveSummaries() {
        guard writable else { return }
        let encoder = JSONEncoder()
        var top: [String: Any] = [:]
        for (k, s) in summaries {
            if let d = try? encoder.encode(s), let o = try? JSONSerialization.jsonObject(with: d) { top[k] = o }
        }
        SBFiles.queue.async { SBFiles.writeJSON(top, SBPaths.summaries) }
    }

    // MARK: Scan

    func stateOf(_ e: SBEntry) -> String {
        if !e.isOpen { return e.parked == true ? "parked" : e.archived == true ? "archived" : "closed" }
        if e.agent == "shell" { return "shell" }
        if e.screen == "working" { return "working" }
        if e.screen == "permission" { return "permission" }
        guard let s = e.summary else { return "reading" }
        let kind = s.kind ?? "info"
        if ["question", "review", "heads_up"].contains(kind), let ack = e.ack_key, ack == e.summary_key {
            return "handled"     // you marked this message as handled; a new agent message brings it back
        }
        return kind
    }

    private func defaultClass(_ cwd: String?) -> String {
        (cwd ?? "").hasPrefix(SBPaths.home + "/Brain") ? "Brain" : "Work"
    }

    private func basename(_ p: String?) -> String {
        var s = p ?? ""
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return (s as NSString).lastPathComponent
    }

    /// Like Claude Code: the name you gave it (/rename), else Claude's own terminal
    /// title, else the summary's title, else the folder name.
    private func sessionName(_ e: SBEntry, transcriptTitle: String?, terminalTitle: String) -> String {
        if e.agent == "claude", let t = transcriptTitle, !t.isEmpty { return t }
        if let t = SBScreen.cleanTerminalTitle(terminalTitle) { return t }
        if let t = e.summary?.title.map(SBScreen.strip), !t.isEmpty { return t }
        let b = basename(e.cwd)
        return b.isEmpty ? "untitled" : b
    }

    func scan() async {
        guard loaded, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let t0 = now   // entries created or reopened after this are not in this scan's snapshot
        let ttys = SessionsAPI.terminalList().map(\.tty).filter { !$0.isEmpty }
        // The spares' Claude runs here too: not "elsewhere", though not a session yet.
        let ours = ttys + SBSpares.shared.ttys
        let agents = await Task.detached(priority: .utility) { SBBackground.agents(onTTYs: ttys) }.value
        var app: SBClaudeApp.Index?
        if t0 - claudeAppAt >= Self.claudeAppEvery {
            claudeAppAt = t0
            app = await Task.detached(priority: .utility) { SBClaudeApp.index() }.value
        }
        var outside: [SBBackground.Agent]?
        if t0 - elsewhereAt >= Self.elsewhereEvery {
            elsewhereAt = t0
            outside = await Task.detached(priority: .utility) {
                SBBackground.agentsElsewhere(notOn: ours) + SBClaudeApp.agents()
            }.value
        }
        merge(t0: t0, agents: agents)
        if let outside { mergeElsewhere(outside) }
        if let app { mergeClaudeApp(app) }
        SBSpares.shared.tick()
        publish()
        if t0 - linksAt >= Self.linksEvery { linksAt = t0; refreshLinks() }
    }

    // MARK: Links and briefs

    /// How often to look for new links in the open sessions' transcripts.
    static let linksEvery = 10.0

    private func refreshLinks() {
        guard !linksRunning else { return }
        let open = reg.sessions.values.filter { $0.isOpen && $0.agent == "claude" }
            .compactMap { e in e.session_id.map { (sid: $0, loginDir: e.login_dir) } }
        guard !open.isEmpty else { return }
        linksRunning = true
        Task.detached(priority: .utility) {
            let found = SBLinks.index(open)
            var sizes: [String: Int] = [:]
            for s in open { sizes[s.sid] = SBLinks.transcriptSize(s.sid) }
            await MainActor.run {
                let sb = Switchboard.shared
                sb.linksRunning = false
                sb.links.merge(found) { _, new in new }
                sb.transcriptSizes = sizes
                sb.scheduleBriefs()
                sb.publish()
            }
        }
    }

    /// Read a session's conversation again when it grew and its agent stopped: the
    /// session in front after 90 s, the others after 15 minutes. Two at a time.
    private func scheduleBriefs() {
        guard summariesOn else { return }
        let focusedSF = SessionsStore.shared.focusedSurfaceID
        let candidates = reg.sessions.values.filter { $0.isOpen && $0.agent == "claude" && $0.session_id != nil }
            .sorted { a, b in
                let fa = a.surface_id != nil && a.surface_id == focusedSF, fb = b.surface_id != nil && b.surface_id == focusedSF
                return fa != fb ? fa : (a.last_activity ?? 0) > (b.last_activity ?? 0)
            }
        for e in candidates {
            guard pendingBriefs.count < 2, let sid = e.session_id, !pendingBriefs.contains(sid),
                  let size = transcriptSizes[sid], size > 0 else { continue }
            if e.state == "working" || e.screen == "working" { continue }
            if now - (failedBriefs[sid] ?? 0) < 300 { continue }
            if let b = briefs[sid] {
                let focused = e.surface_id != nil && e.surface_id == focusedSF
                if size - b.size < 2000 || now - b.at < (focused ? 90 : 900) { continue }
            }
            requestBrief(sid)
        }
    }

    private func requestBrief(_ sid: String) {
        pendingBriefs.insert(sid)
        publish()
        Task.detached(priority: .utility) {
            let b = SBLinks.brief(sid)
            await MainActor.run {
                let sb = Switchboard.shared
                sb.pendingBriefs.remove(sid)
                if let b {
                    sb.briefs[sid] = b
                    let all = sb.briefs
                    SBFiles.queue.async { SBLinks.saveBriefs(all) }
                } else {
                    sb.failedBriefs[sid] = sb.now
                }
                sb.publish()
            }
        }
    }

    /// Conversations that run in another terminal (cmux, Terminal, an editor). They show as
    /// closed here ("· cmux"), so the sidebar and search list them; opening one asks, ends it
    /// there and resumes it here. Before this, only sessions known from the cmux days showed:
    /// one started in cmux later never appeared.
    private func mergeElsewhere(_ agents: [SBBackground.Agent]) {
        let now = self.now
        var seenElsewhere = Set<String>()
        defer { elsewhereKeys = seenElsewhere }
        for a in agents {
            guard let sid = a.sid else { continue }
            let key = "\(a.kind):\(sid)"
            let known = reg.sessions[key]
            // Running here, opening here, or in a login switch: this app owns it.
            if let x = known, x.isOpen || now - (x.opening_at ?? 0) < 25 || switching.contains(key) { continue }
            var e = known ?? {
                var n = SBEntry(key: key, agent: a.kind)
                n.session_id = sid
                n.cls = defaultClass(a.cwd)
                n.labels = []
                n.first_seen = now
                n.custom_name = false
                n.open = false
                // Sorted with the other closed sessions by when it last did something.
                n.closed_at = a.transcriptMtime ?? now
                n.app_only = a.inClaudeApp ? true : nil
                return n
            }()
            e.backend = a.inClaudeApp ? "claude-app" : "cmux"
            e.closed_reason = e.backend
            e.pid = a.pid
            e.login_dir = a.loginDir
            if let mt = a.transcriptMtime { e.last_activity = mt }
            if e.custom_name != true {
                e.cwd = a.cwd ?? e.cwd
                if let t = a.transcriptTitle, !t.isEmpty {
                    e.name = t
                } else if e.name == nil || e.name!.isEmpty {
                    let ask = a.kind == "claude" ? SBBackground.lookupConversation(sid)?.firstAsk : nil
                    e.name = ask ?? sessionName(e, transcriptTitle: nil, terminalTitle: "")
                }
            }
            e.state = stateOf(e)
            reg.sessions[key] = e
            seenElsewhere.insert(key)
        }
        if !agents.isEmpty { save() }
    }

    /// The Claude app's Code sessions that do not run there now: listed as closed ("Claude
    /// app"), so the sidebar and search show them, with the app's names. Opening one resumes
    /// it here. One archived in the app (or gone from it) goes here too, unless it was opened
    /// here since: then it is a Switchboard session like any other.
    private func mergeClaudeApp(_ app: SBClaudeApp.Index) {
        let now = self.now
        var listed = Set<String>()
        var changed = false
        for s in app.sessions {
            let key = "claude:\(s.sid)"
            listed.insert(key)
            let known = reg.sessions[key]
            if known == nil && removedFromApp.contains(s.sid) { continue }
            // Running here, opening here, in a login switch, running in the app (mergeElsewhere
            // has it), or a Switchboard session that has not been in the app since.
            if let x = known, x.isOpen || now - (x.opening_at ?? 0) < 25 || switching.contains(key)
                || elsewhereKeys.contains(key) || x.backend != "claude-app" { continue }
            var e = known ?? {
                var n = SBEntry(key: key, agent: "claude")
                n.session_id = s.sid
                n.cls = defaultClass(s.cwd)
                n.labels = []
                n.first_seen = now
                n.custom_name = false
                n.open = false
                n.app_only = true
                n.backend = "claude-app"
                n.closed_reason = "claude-app"
                return n
            }()
            let before = [e.name, e.cwd, e.login_dir, e.last_message, e.closed_at.map { "\($0)" }]
            if e.custom_name != true, !s.title.isEmpty { e.name = s.title }
            if e.name == nil || e.name!.isEmpty {
                e.name = SBBackground.lookupConversation(s.sid)?.firstAsk ?? sessionName(e, transcriptTitle: nil, terminalTitle: "")
            }
            e.cwd = s.cwd ?? e.cwd
            if let l = s.loginDir { e.login_dir = l }
            e.last_message = s.wrapUp ?? e.last_message
            e.closed_at = max(e.closed_at ?? 0, s.lastActivity)
            e.last_activity = max(e.last_activity ?? 0, s.lastActivity)
            e.state = stateOf(e)
            if known == nil || before != [e.name, e.cwd, e.login_dir, e.last_message, e.closed_at.map { "\($0)" }] {
                reg.sessions[key] = e
                changed = true
            }
        }
        if app.complete {
            let gone = reg.sessions.filter { k, e in
                e.app_only == true && e.backend == "claude-app" && !e.isOpen && e.pinned == nil && !listed.contains(k)
                    && !elsewhereKeys.contains(k) && now - (e.opening_at ?? 0) >= 25 && !switching.contains(k)
            }.keys
            for k in gone { reg.sessions.removeValue(forKey: k) }
            if !gone.isEmpty { changed = true }
            let inApp = Set(app.sessions.map(\.sid))
            if !removedFromApp.isSubset(of: inApp) {
                removedFromApp.formIntersection(inApp)
                UserDefaults.standard.set(Array(removedFromApp), forKey: "sessions.claudeApp.removed")
            }
        }
        if changed { save() }
    }

    /// Where a session that runs outside Switchboard runs, for messages.
    private func elsewhereName(_ e: SBEntry?) -> String {
        e?.backend == "claude-app" ? "the Claude app" : "cmux or another terminal"
    }

    private func merge(t0: Double, agents: [SBBackground.Agent]) {
        let now = self.now
        let terms = SessionsAPI.terminalList()   // fresh: tabs may have opened or closed meanwhile
        let byTTY = Dictionary(terms.map { ($0.tty, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var perTab: [String: Int] = [:]
        let found = agents.compactMap { a in byTTY[a.tty].map { (a, $0) } }
        for (_, t) in found { perTab["g:" + t.tab, default: 0] += 1 }

        for (a, t) in found {
            let wid = "g:" + t.tab, sf = t.id
            let title = !t.programTitle.isEmpty ? t.programTitle : (!t.title.isEmpty ? t.title : t.tabTitle)
            let screen = screenOf(sf)
            var key = a.sid.map { "\(a.kind):\($0)" } ?? "surface:\(sf)"
            if a.sid == nil, let known = reg.sessions.first(where: { $0.value.surface_id == sf
                && ($0.value.isOpen || now - ($0.value.opening_at ?? 0) < 25)
                && !$0.key.hasPrefix("surface:") && !$0.key.hasPrefix("shell:") })?.key {
                // No id on the command line or in a session file (yet): this terminal belongs to
                // the session it already showed, or the one we just opened it for.
                key = known
            }
            let cwd = a.cwd ?? (t.cwd.isEmpty ? nil : t.cwd)
            // The same terminal now runs another conversation (after /clear, a fork, a resume):
            // carry the name, class and labels over.
            if reg.sessions[key] == nil,
               let old = reg.sessions.first(where: { $0.value.surface_id == sf && $0.value.isOpen && $0.key != key })?.key,
               var moved = reg.sessions.removeValue(forKey: old) {
                moved.key = key
                moved.session_id = a.sid
                moved.agent = a.kind
                moved.was = old
                reg.sessions[key] = moved
            }
            var e = reg.sessions[key] ?? {
                var n = SBEntry(key: key, agent: a.kind)
                n.session_id = a.sid
                n.name = title
                n.cls = defaultClass(cwd)
                n.labels = []
                n.login_dir = a.loginDir
                n.first_seen = now
                n.custom_name = false
                return n
            }()
            if let given = pendingNames.removeValue(forKey: sf) {
                e.name = given.name
                e.custom_name = true
            }
            if e.custom_name != true {
                e.cwd = e.cwd ?? cwd
                if e.backend == "claude-app", a.transcriptTitle == nil, let n = e.name, !n.isEmpty {
                    // Moved here from the Claude app: it keeps the app's name (most of the app's
                    // conversation files do not have it), not the terminal's title.
                    e.custom_name = true
                } else {
                    e.name = sessionName(e, transcriptTitle: a.transcriptTitle, terminalTitle: title)
                }
            }
            e.shared_ws = (perTab[wid] ?? 0) > 1
            e.tab_title = nil
            e.open = true
            e.closed_at = nil
            e.closed_reason = nil
            e.opening_at = nil
            e.workspace_id = wid
            e.surface_id = sf
            e.pid = a.pid
            e.cwd = cwd ?? e.cwd
            e.branch = a.branch
            e.last_seen = now
            e.backend = "ghostty"
            e.app_only = nil
            // You switch logins on purpose (quota), so the running login is the truth.
            // Reopen always uses the login a session last ran with.
            e.login_dir = a.loginDir
            let st = SBScreen.state(screen)
            e.screen = st
            e.working_line = st == "working" ? SBScreen.workingLine(screen) : ""
            e.tail = SBScreen.cleanTail(screen)
            e.last_message = nil
            e.last_message_at = nil
            if let mt = a.transcriptMtime { e.last_activity = mt }
            if let sid = a.sid { e.artifacts = Array((artifacts[sid] ?? []).suffix(10)) }
            let skey = SBScreen.summaryKey(screen)
            if st != "working", let tail = e.tail, !tail.isEmpty {
                if let s = summaries[skey] {
                    e.summary = s
                } else {
                    // A new agent message: show "Reading" until Haiku answers, never the old text.
                    if e.summary_key != skey { e.summary = nil }
                    requestSummary(skey, tail)
                }
            }
            if st == "working" { e.summary = nil }
            e.summary_key = skey
            e.split = t.surfacesInTab > 1
            e.state = stateOf(e)
            if Self.needsStates.contains(e.state ?? "") {
                // From when the agent stopped (a summary that is still being read does not count).
                if needsSince[key] == nil { needsSince[key] = min(e.last_activity ?? now, now) }
            } else {
                needsSince[key] = nil
            }
            reg.sessions[key] = e
            seen.insert(key)
        }

        // One window holds every session; the tabs of a session share a "ws" id. A session
        // with no agent in any of its tabs is a shell session, so every session shows in the sidebar.
        let agentSurfaces = Set(found.map { $0.1.id })
        var byWS: [String: [SessionsAPI.Terminal]] = [:]
        for t in terms where !t.ws.isEmpty { byWS[t.ws, default: []].append(t) }
        let agentWSs = Set(byWS.filter { $0.value.contains { agentSurfaces.contains($0.id) } }.keys)
        recentNew = recentNew.filter { now - $0.value < 120 }
        pendingNames = pendingNames.filter { now - $0.value.at < 300 }
        needsSince = needsSince.filter { seen.contains($0.key) }
        let liveIDs = Set(terms.map(\.id))
        screenMemo = screenMemo.filter { liveIDs.contains($0.key) }
        for (ws, ts) in byWS where !agentWSs.contains(ws) {
            let k = "shell:" + ws
            var e: SBEntry
            if let x = reg.sessions[k] {
                e = x
            } else {
                // A Claude session starts in a shell: give it a moment before calling it a shell.
                if ts.contains(where: { now - (recentNew[$0.id] ?? 0) < 20 }) { continue }
                let cwd0 = ts[0].cwd.isEmpty ? SBPaths.home : ts[0].cwd
                e = SBEntry(key: k, agent: "shell")
                e.labels = []
                e.cls = defaultClass(cwd0)
                e.first_seen = now
                e.custom_name = false
                e.backend = "ghostty"
                e.last_activity = now
            }
            let t = ts.first(where: { $0.id == e.surface_id }) ?? ts[0]
            e.open = true
            e.closed_at = nil
            e.closed_reason = nil
            e.surface_id = t.id
            e.workspace_id = "g:" + t.tab
            reg.sessions[k] = e
            seen.insert(k)
        }

        // Shell sessions: open while their terminal exists. Name = folder; line = what runs in it.
        let bySurface = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (k, var e) in reg.sessions where e.agent == "shell" && e.isOpen {
            if k.hasPrefix("shell:") && agentWSs.contains(String(k.dropFirst(6))) { continue }   // an agent took over: this row closes
            guard let t = bySurface[e.surface_id ?? ""] else { continue }
            let oldCwd = e.cwd
            if !t.cwd.isEmpty { e.cwd = t.cwd }
            e.workspace_id = "g:" + t.tab
            if e.custom_name != true {
                let b = basename(e.cwd)
                e.name = b.isEmpty ? "~" : b
            }
            // A title that is a path (~/Simplero) is the shell at its prompt: nothing runs.
            let raw = SBScreen.strip(!t.programTitle.isEmpty ? t.programTitle : t.title)
            let line = raw.hasPrefix("/") || raw.hasPrefix("~") ? "" : SBScreen.cleanTerminalTitle(raw) ?? ""
            if line != (e.working_line ?? "") || e.cwd != oldCwd { e.last_activity = now }
            e.working_line = line
            e.last_seen = now
            e.state = stateOf(e)
            reg.sessions[k] = e
            seen.insert(k)
        }

        // Sessions not running any more.
        var closedNow: [String] = []
        for (k, var e) in reg.sessions where e.isOpen && !seen.contains(k) {
            if (e.first_seen ?? 0) > t0 || (e.opening_at ?? 0) > t0 { continue }   // created or reopened while this scan ran
            e.open = false
            e.closed_at = now
            e.closed_reason = e.closing ?? "vanished"
            e.closing = nil
            e.screen = nil
            if e.pinned != nil { e.working_line = "" }
            e.state = stateOf(e)
            reg.sessions[k] = e
            closedNow.append(k)
        }
        // A shell is gone with its terminal; a pinned one stays (opening it starts it again).
        for k in closedNow where reg.sessions[k]?.agent == "shell" && reg.sessions[k]?.pinned == nil { reg.sessions.removeValue(forKey: k) }
        save()
    }

    /// The last 120 lines of a terminal. Copying them means copying the whole scrollback,
    /// which is slow for long sessions, so it happens only when the screen changed and the
    /// agent is not working; otherwise the last copy (or the active area) does.
    private var screenMemo: [String: (active: String, screen: String)] = [:]

    private func screenOf(_ sf: String) -> String {
        guard let active = SessionsAPI.activeText(sf) else { return "" }
        if let m = screenMemo[sf], m.active == active { return m.screen }
        if SBScreen.state(active) == "working" { return active }
        let screen = SessionsAPI.screenText(sf) ?? active
        screenMemo[sf] = (active, screen)
        return screen
    }

    private func requestSummary(_ key: String, _ tail: String) {
        guard summariesOn, !pendingSummaries.contains(key), now - (failedSummaries[key] ?? 0) > 60 else { return }
        pendingSummaries.insert(key)
        SBBackground.summaryQueue.addOperation {
            let s = SBBackground.summarize(tail)
            Task { @MainActor in Switchboard.shared.summaryDone(key, s) }
        }
    }

    private func summaryDone(_ key: String, _ s: SBSummary?) {
        pendingSummaries.remove(key)
        failedSummaries = failedSummaries.filter { now - $0.value < 600 }
        guard let s else { failedSummaries[key] = now; return }
        summaries[key] = s
        summaryOrder.removeAll { $0 == key }
        summaryOrder.append(key)
        if summaries.count > 2000 {
            let inUse = Set(reg.sessions.values.compactMap(\.summary_key))
            var dropped = 0
            summaryOrder.removeAll { k in
                guard dropped < 500, !inUse.contains(k) else { return false }
                summaries.removeValue(forKey: k)
                dropped += 1
                return true
            }
        }
        saveSummaries()
        // Show it now, not at the next scan.
        for (k, var e) in reg.sessions where e.isOpen && e.summary_key == key && e.screen != "working" {
            e.summary = s
            if e.custom_name != true && e.agent != "shell" && (e.name ?? "").isEmpty { e.name = s.title }
            e.state = stateOf(e)
            reg.sessions[k] = e
        }
        publish()
    }

    /// Every 60 s: plan usage (every 3 minutes), artifact links.
    private func slowWork() {
        let sessions = reg.sessions.values.compactMap { e in e.session_id.map { ($0, e.login_dir) } }
        let fetchUsage = now - usageAt >= 180
        if fetchUsage { usageAt = now }
        Task.detached(priority: .utility) {
            var fresh: [String: [String: Any]] = [:]
            if fetchUsage {
                for d in SBLogins.dirs { if let u = SBBackground.fetchUsage(d) { fresh[d] = u } }
            }
            SBBackground.indexArtifacts(sessions.map { (sid: $0.0, loginDir: $0.1) })
            let arts = SBBackground.artifactsBySession()
            await MainActor.run {
                let sb = Switchboard.shared
                sb.artifacts = arts
                if fetchUsage { sb.updateUsage(fresh) }
            }
        }
    }

    /// Usage per login, with a history of the weekly % (one point per 20 minutes, 7 days)
    /// for the graph in the panel.
    private func updateUsage(_ fresh: [String: [String: Any]]) {
        var hist = (SBFiles.readJSON(SBPaths.usageHistory) as? [String: [[Any]]]) ?? [:]
        let now = self.now
        var out: [String: Any] = [:]
        for d in SBLogins.dirs {
            var u = fresh[d] ?? ((usage[d] as? [String: Any]) ?? [:])
            u.removeValue(forKey: "hist")
            var h = (hist[d] ?? []).filter { now - (($0.first as? NSNumber)?.doubleValue ?? 0) < 7 * 86400 }
            if let wk = u["wk"] as? [String: Any], let p = wk["p"] {
                let last = (h.last?.first as? NSNumber)?.doubleValue ?? 0
                if h.isEmpty || now - last > 1200 {
                    h.append([Int(now), p, (u["h5"] as? [String: Any])?["p"] ?? NSNull()])
                }
            }
            hist[d] = h
            u["hist"] = h
            out[d] = u
        }
        if writable { SBFiles.queue.async { SBFiles.writeJSON(hist, SBPaths.usageHistory) } }
        usage = out
        publish()
    }

    // MARK: Feeding the pages

    private func compact(_ e: SBEntry) -> [String: Any] {
        let s = e.summary
        let st = e.state ?? stateOf(e)
        // Reply buttons only for a real choice the agent offered (a question or a prompt).
        let offered = (st == "question" || st == "permission") ? (s?.replies ?? []) : []
        let reps: [[String]] = offered.prefix(3).compactMap { r in
            guard let send = r.send, !send.isEmpty else { return nil }
            return [r.label ?? send, send]
        }
        var ns: String
        switch st {
        case "working", "shell": ns = e.working_line ?? ""
        case "permission": ns = "Answer the permission dialog in the terminal."
        default: ns = (s?.next_step).flatMap { $0.isEmpty ? nil : $0 } ?? s?.said ?? ""
        }
        var name = e.name ?? "untitled"
        if name.isEmpty { name = "untitled" }
        if e.shared_ws == true && e.isOpen {
            let extra = (s?.title).flatMap { $0.isEmpty ? nil : $0 } ?? SBLogins.short(e.login_dir)
            name = "\(name) · \(extra)"
        }
        func n(_ x: Any?) -> Any { x ?? NSNull() }
        // The panel's links and brief: open sessions only.
        let sid = e.isOpen ? e.session_id : nil
        let lk: [[String]] = (sid.flatMap { links[$0] } ?? []).prefix(30).map { l in
            [l.kind, l.url, SBLinks.label(l), l.kind == "artifact" ? (l.login.map { SBLogins.short($0) } ?? "") : ""]
        }
        let br = sid.flatMap { briefs[$0] }
        return [
            "k": e.key, "n": name, "c": e.cls ?? "Work", "lb": e.labels ?? [],
            "lk": lk, "gl": br?.goal ?? "", "op": (br?.open ?? []).map { [$0.who ?? "", $0.text] },
            "bp": sid.map { pendingBriefs.contains($0) } ?? false,
            "lg": e.agent == "shell" ? NSNull() as Any : SBLogins.short(e.login_dir) as Any, "ld": n(e.login_dir), "a": n(e.agent),
            "st": st, "u": s?.urgent == true, "ns": String(ns.prefix(160)), "t": String((s?.title ?? "").prefix(60)),
            "sd": String((s?.said ?? "").prefix(300)), "lm": String((e.last_message ?? "").prefix(300)),
            "lma": Int(e.last_message_at ?? 0), "wl": String((e.working_line ?? "").prefix(160)),
            "ws": e.isOpen ? n(e.workspace_id) : NSNull() as Any, "sf": e.isOpen ? n(e.surface_id) : NSNull() as Any,
            "o": e.isOpen, "pk": e.parked == true,
            "la": Int(e.last_activity ?? e.last_seen ?? 0), "ca": Int(e.closed_at ?? 0),
            "cr": n(e.closed_reason), "cwd": SBPaths.tilde(e.cwd ?? ""), "br": n(e.branch),
            "rm": NSNull(), "rp": reps, "art": Array((e.artifacts ?? []).suffix(3)),
            "be": e.backend ?? "cmux",
            "el": !e.isOpen && elsewhereKeys.contains(e.key),
            "ar": e.archived == true && !e.isOpen, "aa": Int(e.archived_at ?? 0),
            "was": n(e.was),
            "nsn": Int(e.isOpen ? (needsSince[e.key] ?? 0) : 0),
            "pn": n(e.pinned), "pc": n(e.pin_cmd),
        ]
    }

    func payloadObject() -> [String: Any] {
        let sess = reg.sessions.values.sorted { ($0.last_activity ?? 0) > ($1.last_activity ?? 0) }
        let live = sess.filter(\.isOpen)
        // Pins are always there, running or not.
        let pins = sess.filter { !$0.isOpen && $0.pinned != nil }
        let recent = sess.filter { !$0.isOpen && $0.pinned == nil && ($0.parked == true || ($0.archived != true && now - ($0.closed_at ?? 0) < 14 * 86400)) }
        let archived = sess.filter { $0.archived == true && !$0.isOpen && $0.pinned == nil }
            .sorted { ($0.archived_at ?? 0) > ($1.archived_at ?? 0) }.prefix(80)
        let rows = live + pins + recent.prefix(max(0, 150 - live.count)) + archived
        var payload: [String: Any] = [
            "v": 1, "at": Int(now), "hub": NSNull(),
            "classes": reg.classes, "labels": reg.labels,
            "spares": SBSpares.shared.info(),
            "s": rows.map(compact), "ot": [], "grp": [], "use": usage,
        ]
        let vanished = sess.filter { !$0.isOpen && $0.parked != true && $0.closed_reason == "vanished" }
        if let newest = vanished.compactMap(\.closed_at).max() {
            let batch = vanished.filter { ($0.closed_at ?? 0) > newest - 120 }
            if batch.count >= 3 { payload["restore"] = ["n": batch.count, "at": Int(newest)] }
        }
        return payload
    }

    /// Send the sidebar and the panel the current data, if it changed.
    func publish() {
        guard loaded else { return }
        var p = payloadObject()
        p["at"] = 0
        guard let same = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys]) else { return }
        if same == lastPushed { return }
        lastPushed = same
        SBRemote.shared.sessionsChanged()
        p["at"] = Int(now)
        guard let data = try? JSONSerialization.data(withJSONObject: p) else { return }
        if let decoded = try? JSONDecoder().decode(SidebarPayload.self, from: data) {
            SessionsStore.shared.payload = decoded
        }
        let json = String(decoding: data, as: UTF8.self)
        SessionsWeb.shared.setData(json)
        SessionsWeb.banner.setData(json)
    }

    /// The current data as JSON, for a page that just loaded.
    func currentJSON() -> String? {
        guard loaded, let d = try? JSONSerialization.data(withJSONObject: payloadObject()) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: Search

    func search(_ q: String, limit: Int = 80) -> [[String: Any]] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [(Int, Int, Double, SBEntry)] = []
        for e in reg.sessions.values {
            let sm = e.summary
            let hay = [e.name, e.tab_title, sm?.title, sm?.said, sm?.next_step, (e.labels ?? []).joined(separator: " "), e.cls,
                       SBLogins.short(e.login_dir), e.cwd, e.branch, e.session_id, e.last_message]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
            guard words.allSatisfy({ hay.contains($0) }) else { continue }
            let nameHit = words.allSatisfy { (e.name ?? "").lowercased().contains($0) }
            hits.append((e.isOpen ? 0 : 1, nameHit ? 0 : 1, -(e.last_activity ?? e.closed_at ?? 0), e))
        }
        hits.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        return hits.prefix(limit).map { compact($0.3) }
    }

    /// A pasted conversation id: where it is on this Mac, to offer resuming it.
    func lookupSessionID(_ sid: String) async -> [String: Any]? {
        let found = await Task.detached(priority: .userInitiated) { () -> (SBBackground.Conversation, String?)? in
            guard let info = SBBackground.lookupConversation(sid) else { return nil }
            return (info, info.account.flatMap { SBLogins.byAccount()[$0] })
        }.value
        guard let (info, owner) = found else { return nil }
        let e = reg.sessions["claude:" + sid]
        let login = e?.login_dir ?? owner
        func n(_ x: Any?) -> Any { x ?? NSNull() }
        return ["id": sid, "cwd": n(e?.cwd ?? info.cwd), "title": n(e?.name ?? info.title ?? info.firstAsk), "login": n(login),
                "lg": login.map { SBLogins.short($0) as Any } ?? NSNull(), "known": e != nil, "open": e?.isOpen == true,
                "k": "claude:" + sid]
    }

    // MARK: Opening terminals

    /// How sessions start Claude: like the cc / ccl / ccm aliases (sync MCP sign-ins,
    /// drop API-key and token variables, then claude). SWITCHBOARD_CLAUDE replaces
    /// the claude command (a test copy runs a stand-in).
    /// The default login (~/.claude) runs without CLAUDE_CONFIG_DIR, even when the app
    /// itself was started with one.
    static func claudeLaunch(_ loginDir: String?) -> String {
        let unsetLogin = (loginDir ?? "~/.claude") == "~/.claude" ? "-u CLAUDE_CONFIG_DIR " : ""
        if let fake = ProcessInfo.processInfo.environment["SWITCHBOARD_CLAUDE"], !fake.isEmpty { return "env \(unsetLogin)\(fake)" }
        let sync = SBPaths.home + "/.local/bin/sync-claude-mcp"
        let pre = FileManager.default.fileExists(atPath: sync) ? shellQuote(sync) + " >/dev/null 2>&1; " : ""
        return pre + "env \(unsetLogin)-u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT claude"
    }

    static func shellQuote(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9@%+=:,./_-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func resumeCommand(_ e: SBEntry) -> String? {
        if let sid = e.session_id, !sid.isEmpty {
            switch e.agent {
            case "claude": return "\(Self.claudeLaunch(e.login_dir)) --resume \(sid) --dangerously-skip-permissions"
            case "codex": return "codex resume \(sid)"
            case "opencode": return "opencode --session \(sid)"
            default: break
            }
        }
        return e.resume_cmd
    }

    /// A terminal for an agent: a new session, or a tab of the session `tabOf` is in.
    private func openAgentTerminal(cwd: String?, command: String, loginDir: String?, focus: Bool,
                                   split: Bool = false, tabOf: String? = nil) -> String? {
        var env: [String: String] = [:]
        if let d = loginDir, d != "~/.claude" { env["CLAUDE_CONFIG_DIR"] = SBPaths.expand(d) }
        let folder = SBPaths.expand(cwd ?? Self.defaultFolder)
        // No fixed title: it would hide the one Claude sets (its own name, or the /rename name).
        guard let made = SessionsAPI.openTab(cwd: folder, input: command + "\n", env: env, focus: focus, split: split, tabOf: tabOf) else { return nil }
        recentNew[made.id] = now
        return made.id
    }

    // MARK: Actions

    /// Run an action from the sidebar, the panel or a menu. Returns whether it worked and
    /// a message for the person.
    func dispatch(_ msg: [String: Any]) async -> (Bool, String) {
        guard loaded else { return (false, "Switchboard is still starting.") }
        let op = msg["op"] as? String ?? ""
        let k = msg["k"] as? String ?? ""
        let focus = msg["focus"] as? Bool ?? true
        if focus { SessionSwitchLog.becauseIfNone("Switchboard op “\(op)” (the phone, a check, or a script)") }
        defer { publish() }
        switch op {
        case "open", "unpark":
            if msg["end_elsewhere"] as? Bool == true, !(await endElsewhere(k)) {
                return (false, "It still runs outside Switchboard (\(elsewhereName(reg.sessions[k]))) and did not stop. Close it there, then reopen it here.")
            }
            let r = openEntry(k, focus: focus)
            return (r.ok, r.message)
        case "park": return close(k, park: true)
        case "close": return close(k, park: false)
        case "done": return done(k)
        case "switch": return await switchLogin(k, msg["login"] as? String ?? "", focus: focus)
        case "new_shell":
            let r = newShell(msg["cwd"] as? String, focus: focus)
            if focus, let sf = r.surface { SessionsAPI.focusTerminal(sf) }
            return (r.ok, r.message)
        case "new":
            // From the sidebar's new-session form: a first message, files and a name, all optional.
            let r = newClaude(msg["login"] as? String ?? "~/.claude", focus: msg["select"] as? Bool ?? true, cwd: msg["cwd"] as? String,
                              prompt: msg["prompt"] as? String, name: msg["name"] as? String, files: msg["files"] as? [String] ?? [])
            return (r.ok, r.message)
        case "resume_id": return await resumeID(msg["id"] as? String ?? "", login: msg["login"] as? String)
        case "restore": return await restore(msg["keys"] as? [String])
        case "cls": return edit(k, cls: msg["cls"] as? String)
        case "label": return edit(k, label: msg["label"] as? String ?? "")
        case "rename": return edit(k, name: msg["name"] as? String ?? "")
        case "ack": return ack(k)
        case "forget": return forget(k)
        case "send": return send(k, msg["text"] as? String ?? "")
        case "remember_open": return rememberOpen()
        case "pin": return pin(k)
        case "unpin": return unpin(k)
        case "pin_order": return pinOrder(msg["keys"] as? [String] ?? [])
        case "pin_command":
            let r = pinCommand(msg["cmd"] as? String ?? "", cwd: msg["cwd"] as? String, name: msg["name"] as? String)
            return (r.ok, r.message)
        default: return (false, "Unknown action “\(op)”.")
        }
    }

    func entry(_ k: String) -> SBEntry? { reg.sessions[k] }

    private func update(_ k: String, _ body: (inout SBEntry) -> Void) {
        guard var e = reg.sessions[k] else { return }
        body(&e)
        reg.sessions[k] = e
        save()
    }

    /// Show a session, or resume it in a new terminal. Returns the new terminal's id.
    @discardableResult
    func openEntry(_ k: String, focus: Bool = true, split: Bool = false, tabOf: String? = nil) -> (ok: Bool, message: String, surface: String?) {
        guard let e = reg.sessions[k] else { return (false, "Unknown session.", nil) }
        if e.isOpen, let sf = e.surface_id, let view = SessionsAPI.surface(id: sf) {
            if focus { SessionsAPI.focus(view) }
            startPinCommandIfIdle(k)
            return (true, "Opened.", nil)
        }
        // A pinned shell (lazygit) whose terminal is gone: a new one, running its command again.
        if e.agent == "shell", e.pinned != nil {
            let r = openShellPin(k, focus: focus)
            if focus, let sf = r.surface { SessionsAPI.focusTerminal(sf) }
            return r
        }
        // A second click before the scan sees the first one running: do not start it twice,
        // but show the terminal it is starting in.
        if !e.isOpen, now - (e.opening_at ?? 0) < 25, let sf = e.surface_id, let view = SessionsAPI.surface(id: sf) {
            if focus { SessionsAPI.focus(view) }
            return (true, "Opening…", nil)
        }
        // (Its terminal is gone, closed before the scan saw it: start it again below.)
        if switching.contains(k) && !switchOpening { return (true, "Switching login…", nil) }
        // The same conversation must never run in two places.
        if runningElsewhere(k) != nil {
            return (false, "“\(e.name ?? "This session")” still runs outside Switchboard (\(elsewhereName(e))). Click its row in the sidebar to move it here.", nil)
        }
        guard let cmd = resumeCommand(e) else { return (false, "No way to resume this session.", nil) }
        guard let sf = openAgentTerminal(cwd: e.cwd, command: cmd, loginDir: e.login_dir, focus: focus, split: split, tabOf: tabOf) else {
            return (false, "Switchboard could not open a terminal.", nil)
        }
        update(k) { x in
            x.opening_at = now
            x.open = false
            x.parked = false
            x.archived = false
            x.surface_id = sf      // the scan ties the agent in this terminal to this session
        }
        return (true, "Reopened.", sf)
    }

    /// The process id of a session that still runs outside this app (in cmux), if any.
    /// The process of a closed session's conversation that runs outside this app's
    /// terminals (cmux, another terminal app), if any.
    func runningElsewhere(_ k: String) -> Int? {
        guard let e = reg.sessions[k], !e.isOpen, let sid = e.session_id, let kind = e.agent, kind != "shell" else { return nil }
        let ours = Set(SessionsAPI.terminalList().compactMap { SBProcesses.deviceOf(ttyPath: $0.tty) })
        return SBBackground.findAgent(kind: kind, sid: sid, notOn: ours, hint: e.pid)
    }

    /// End a session's process outside this app (its cmux tab stays, at a shell prompt).
    /// True once it is gone.
    private func endElsewhere(_ k: String) async -> Bool {
        guard let pid = runningElsewhere(k) else { return true }
        for (signal, tries) in [(SIGHUP, 20), (SIGTERM, 12)] {
            kill(pid_t(pid), signal)
            for _ in 0..<tries {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !SBProcesses.isAlive(pid) { return true }
            }
        }
        return false
    }

    /// Close a session: every tab of it (whole), or only the agent's terminal (to replace it).
    func close(_ k: String, park: Bool, whole: Bool = true) -> (Bool, String) {
        guard let e = reg.sessions[k] else { return (false, "Unknown session.") }
        if park && e.pinned != nil { return (false, "“\(e.name ?? "This session")” is pinned, so it is never parked. Right-click it and choose Unpin first.") }
        let park = e.agent == "shell" ? false : park     // a shell has nothing to resume later
        update(k) { x in
            x.parked = park
            x.closing = park ? "parked" : "closed"
        }
        if e.isOpen, let sf = e.surface_id {
            let closed = whole ? SessionsAPI.closeSession(sf) : SessionsAPI.closeTerminal(sf)
            if !closed && !SessionsAPI.closeTerminal(sf) && SessionsAPI.surface(id: sf) != nil {
                return (false, "Switchboard could not close it.")
            }
        }
        if !e.isOpen { update(k) { $0.state = stateOf($0) } }
        return (true, park ? "Parked." : "Closed.")
    }

    /// I'm done with it: close it with every tab and move it to the Archive. Reopening it
    /// from the Archive resumes the conversation and takes it out of the Archive.
    func done(_ k: String) -> (Bool, String) {
        guard let e = reg.sessions[k] else { return (false, "Unknown session.") }
        if e.pinned != nil { return (false, "“\(e.name ?? "This session")” is pinned, so it never goes to the Archive. Right-click it and choose Unpin first.") }
        update(k) { x in
            if x.agent != "shell" {
                x.archived = true
                x.archived_at = now
            }
            x.parked = false
            if !x.isOpen { x.state = stateOf(x) }
        }
        guard e.isOpen, let sf = e.surface_id else { return (true, "Moved to the Archive.") }
        update(k) { $0.closing = "done" }
        if !SessionsAPI.closeSession(sf) && !SessionsAPI.closeTerminal(sf) && SessionsAPI.surface(id: sf) != nil {
            return (false, "Switchboard could not close it.")
        }
        return (true, e.agent == "shell" ? "Closed." : "Closed and moved to the Archive.")
    }

    /// Another terminal of the same session (a shell tab), so a replaced agent comes back
    /// as a tab of that session instead of as a new session.
    private func sessionTabMate(_ e: SBEntry) -> String? {
        let terms = SessionsAPI.terminalList()
        guard let me = terms.first(where: { $0.id == e.surface_id }), !me.ws.isEmpty else { return nil }
        return terms.first(where: { $0.ws == me.ws && $0.tab != me.tab })?.id
    }

    /// Close Claude and resume the same conversation with another login.
    func switchLogin(_ k: String, _ loginDir: String, focus: Bool = true) async -> (Bool, String) {
        guard let e = reg.sessions[k] else { return (false, "Unknown session.") }
        guard e.agent == "claude", e.session_id != nil else { return (false, "Only Claude sessions with a session id can switch login.") }
        guard SBLogins.dirs.contains(loginDir) else { return (false, "Unknown login \(loginDir).") }
        if e.isOpen && e.screen == "working" { return (false, "It is working right now. Stop it (Ctrl+C) or wait, then switch.") }
        guard !switching.contains(k) else { return (false, "It is switching login already.") }
        if !e.isOpen, runningElsewhere(k) != nil {
            return (false, "“\(e.name ?? "This session")” still runs outside Switchboard (\(elsewhereName(e))). Click its row in the sidebar to move it here first.")
        }
        switching.insert(k)
        defer { switching.remove(k) }
        let mate = e.isOpen ? sessionTabMate(e) : nil
        if e.isOpen {
            let (ok, msg) = close(k, park: false, whole: false)
            if !ok { return (ok, msg) }
            // The old Claude must be gone before the new one opens the same conversation.
            if let pid = e.pid {
                for _ in 0..<30 where SBProcesses.isAlive(pid) { try? await Task.sleep(nanoseconds: 150_000_000) }
                if SBProcesses.isAlive(pid) { return (false, "The old Claude did not stop. Try again in a moment.") }
            }
        }
        update(k) { x in
            x.login_dir = loginDir
            x.open = false
            x.closing = nil
            x.opening_at = nil
        }
        switchOpening = true
        let r = openEntry(k, focus: focus, tabOf: mate)
        switchOpening = false
        return (r.ok, r.ok ? "Now on \(SBLogins.short(loginDir))." : r.message)
    }

    /// ⌘N: a new session with a plain shell, no agent. You run what you want in it.
    func newShell(_ cwd: String?, focus: Bool = true) -> (ok: Bool, message: String, surface: String?) {
        var folder = SBPaths.expand(cwd ?? "~")
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) || !isDir.boolValue { folder = SBPaths.home }
        guard let made = SessionsAPI.openTab(cwd: folder, input: nil, env: [:], focus: focus) else {
            return (false, "Switchboard could not open a terminal.", nil)
        }
        let k = "shell:" + made.ws
        var e = SBEntry(key: k, agent: "shell")
        let b = basename(folder)
        e.name = b.isEmpty ? "~" : b
        e.cls = defaultClass(folder)
        e.labels = []
        e.first_seen = now
        e.custom_name = false
        e.open = true
        e.backend = "ghostty"
        e.surface_id = made.id
        e.workspace_id = "g:" + made.tab
        e.cwd = folder
        e.last_activity = now
        e.last_seen = now
        e.state = stateOf(e)
        reg.sessions[k] = e
        save()
        return (true, "Started.", made.id)
    }

    /// A new Claude session with a login, in a folder. With `prompt` (and `files`, whose paths
    /// go below it), Claude starts on that first message. With `focus`, the login's spare
    /// (SBSpares) is used when it is ready: Claude is there at once, and the keyboard is in it.
    func newClaude(_ loginDir: String, focus: Bool = true, cwd: String? = nil, prompt: String? = nil,
                   name: String? = nil, files: [String] = []) -> (ok: Bool, message: String, surface: String?) {
        let folder = SBPaths.expand(cwd ?? Self.defaultFolder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            return (false, "The folder \(cwd ?? folder) does not exist.", nil)
        }
        let prompt = Self.firstMessage(prompt, files: files)
        let label = name.map(SBScreen.strip).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        if focus, let spare = SBSpares.shared.take(loginDir, folder: folder) {
            if let made = SessionsAPI.adoptSpare(spare.controller) {
                recentNew[made.id] = now   // not a shell session while the scan catches up
                if let label { pendingNames[made.id] = (label, now) }
                SessionsAPI.focusTerminal(made.id)
                if !prompt.isEmpty { typeWhenReady(made.id, prompt, since: now, seenAt: nil) }
                return (true, "Started.", made.id)
            }
            SBSpares.close(spare.controller)
        }
        var command = Self.claudeLaunch(loginDir) + " --dangerously-skip-permissions"
        if !prompt.isEmpty {
            // Through a file, not typed into the shell: any length, any characters, line breaks.
            let dir = SBPaths.data + "/prompts"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let file = dir + "/\(UUID().uuidString).txt"
            let text = prompt.hasPrefix("-") ? " " + prompt : prompt     // never read as an option
            guard SBFiles.writeAtomic(Data(text.utf8), file) else { return (false, "Could not save the first message.", nil) }
            command += " \"$(cat \(Self.shellQuote(file)); rm -f \(Self.shellQuote(file)))\""
        }
        // One pane: just Claude. A shell is a tab away (+ in the panel, or ⌘T).
        guard let sf = openAgentTerminal(cwd: folder, command: command, loginDir: loginDir, focus: focus) else {
            return (false, "Switchboard could not open a terminal.", nil)
        }
        if let label { pendingNames[sf] = (label, now) }
        if focus { SessionsAPI.focusTerminal(sf) }
        return (true, "Started.", sf)
    }

    /// Type the first message into a spare once Claude shows its prompt (it may still be
    /// starting when you press Enter), then Enter.
    private func typeWhenReady(_ sf: String, _ text: String, since: Double, seenAt: Double?) {
        guard let view = SessionsAPI.surface(id: sf) else { return }   // closed meanwhile
        var seen = seenAt
        if SBSpares.atPrompt(view) {
            // A moment after the prompt first shows, so Claude reads the paste as input.
            if let s = seen, now - s >= 0.3 { _ = SessionsAPI.sendInput(sf, text: text, enter: true); return }
            if seen == nil { seen = now }
        } else {
            seen = nil
        }
        if now - since > 45 {
            SessionsWeb.shared.webView.evaluateJavaScript("window.Sessions && Sessions.newFailed && Sessions.newFailed()")
            SessionsStore.shared.showFailure("Claude did not get to its prompt within 45 seconds, so your first message was not sent. It is back in the new-session form.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { self.typeWhenReady(sf, text, since: since, seenAt: seen) }
        }
    }

    /// The first message: what you wrote, then the paths of the files you added, one per line.
    static func firstMessage(_ prompt: String?, files: [String]) -> String {
        var parts: [String] = []
        let text = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        let paths = files.filter { !$0.isEmpty }
        if !paths.isEmpty { parts.append(paths.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// Resume a Claude conversation by its id, in its own folder, with the login you pick.
    func resumeID(_ raw: String, login: String?) async -> (Bool, String) {
        guard let r = raw.lowercased().range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression) else {
            return (false, "That is not a session id.")
        }
        let sid = String(raw.lowercased()[r])
        let k = "claude:" + sid
        if reg.sessions[k]?.isOpen == true { let o = openEntry(k); return (o.ok, o.message) }
        guard let info = await lookupSessionID(sid) else { return (false, "No conversation with id \(sid) on this Mac.") }
        let cwd = info["cwd"] as? String
        var isDir: ObjCBool = false
        guard let cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return (false, "The folder of that conversation (\(cwd ?? "unknown")) does not exist any more.")
        }
        let loginDir = login.flatMap { SBLogins.dirs.contains($0) ? $0 : nil } ?? (info["login"] as? String) ?? "~/.claude"
        if reg.sessions[k] == nil {
            var e = SBEntry(key: k, agent: "claude")
            e.session_id = sid
            let title = info["title"] as? String
            e.name = title ?? (basename(cwd).isEmpty ? "resumed session" : basename(cwd))
            e.cls = "Work"
            e.labels = []
            e.first_seen = now
            e.custom_name = title != nil
            reg.sessions[k] = e
        }
        update(k) { x in
            x.login_dir = loginDir
            x.cwd = cwd
        }
        let o = openEntry(k)
        return (o.ok, o.message)
    }

    /// Reopen the sessions that vanished together (or the ones named).
    func restore(_ keys: [String]?) async -> (Bool, String) {
        var cands = reg.sessions.values.filter { !$0.isOpen && $0.parked != true
            && (keys == nil ? $0.closed_reason == "vanished" : keys!.contains($0.key)) }
        if keys == nil {
            // Only the last batch: sessions that vanished within 2 minutes of the newest one.
            guard let newest = cands.compactMap(\.closed_at).max() else { return (true, "Nothing to restore.") }
            cands = cands.filter { ($0.closed_at ?? 0) > newest - 120 }
        }
        var n = 0
        for e in cands {
            if openEntry(e.key, focus: false).ok { n += 1 }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return (true, "Reopened \(n).")
    }

    func edit(_ k: String, cls: String? = nil, label: String? = nil, name: String? = nil) -> (Bool, String) {
        guard reg.sessions[k] != nil else { return (false, "Unknown session.") }
        update(k) { e in
            if let cls, !cls.isEmpty {
                e.cls = cls
                if !reg.classes.contains(cls) { reg.classes.append(cls) }
            }
            if let label {
                let lab = SBScreen.strip(label).lowercased()
                var labs = e.labels ?? []
                if let i = labs.firstIndex(of: lab) {
                    labs.remove(at: i)
                } else if !lab.isEmpty {
                    labs.append(lab)
                    if !reg.labels.contains(lab) { reg.labels.append(lab) }
                }
                e.labels = labs
            }
            if let name, !SBScreen.strip(name).isEmpty {
                e.name = SBScreen.strip(name)
                e.custom_name = true
            }
        }
        return (true, "Saved.")
    }

    func ack(_ k: String) -> (Bool, String) {
        guard reg.sessions[k] != nil else { return (false, "Unknown session.") }
        var handled = false
        update(k) { e in
            e.ack_key = e.ack_key != nil && e.ack_key == e.summary_key ? nil : e.summary_key
            handled = e.ack_key != nil
            e.state = stateOf(e)
        }
        return (true, handled ? "Marked as handled." : "Back in Needs you.")
    }

    func forget(_ k: String) -> (Bool, String) {
        if reg.sessions[k]?.isOpen == true { return (false, "Close it first.") }
        // From the Claude app: the app still has it, so do not list it again.
        if let e = reg.sessions[k], e.backend == "claude-app", let sid = e.session_id {
            removedFromApp.insert(sid)
            UserDefaults.standard.set(Array(removedFromApp), forKey: "sessions.claudeApp.removed")
        }
        reg.sessions.removeValue(forKey: k)
        save()
        return (true, "Removed from the list.")
    }

    func send(_ k: String, _ text: String) -> (Bool, String) {
        guard let e = reg.sessions[k], e.isOpen, let sf = e.surface_id else { return (false, "That session is not running.") }
        let ok = SessionsAPI.sendInput(sf, text: text, enter: true)
        return (ok, ok ? "Sent." : "That terminal is gone.")
    }

    // MARK: Pins

    /// Sessions that stay (Chief of staff, lazygit): in the Pinned row at the top of the
    /// sidebar, not in the lists or the counts, never parked or archived. ⌃1…⌃9 open them.
    private var pinKeys: [String] {
        reg.sessions.values.filter { $0.pinned != nil }.sorted { ($0.pinned ?? 0, $0.key) < ($1.pinned ?? 0, $1.key) }.map(\.key)
    }

    /// Number the pins 0, 1, 2… in this order (the rest after them, as they were).
    private func numberPins(_ order: [String]) {
        let rest = pinKeys.filter { !order.contains($0) }
        for (i, k) in (order.filter { reg.sessions[$0]?.pinned != nil } + rest).enumerated() { reg.sessions[k]?.pinned = i }
        save()
    }

    func pin(_ k: String) -> (Bool, String) {
        guard let e = reg.sessions[k] else { return (false, "Unknown session.") }
        if e.pinned != nil { return (true, "Pinned already.") }
        if e.agent == "shell" && !e.isOpen { return (false, "That terminal is gone.") }
        update(k) { x in
            x.pinned = (reg.sessions.values.compactMap(\.pinned).max() ?? -1) + 1
            x.parked = false
            x.archived = false
            if x.agent == "shell", let cmd = x.working_line?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty {
                // The program that runs in it (lazygit): its name, and what opening the pin starts again.
                x.pin_cmd = cmd
                if x.custom_name != true { x.name = cmd; x.custom_name = true }
            }
        }
        numberPins(pinKeys)
        return (true, "Pinned.")
    }

    func unpin(_ k: String) -> (Bool, String) {
        guard let e = reg.sessions[k], e.pinned != nil else { return (true, "Not pinned.") }
        if e.agent == "shell" && !e.isOpen {
            reg.sessions.removeValue(forKey: k)      // a shell that is not running is nothing without its pin
        } else {
            update(k) { x in x.pinned = nil; x.pin_cmd = nil }
        }
        numberPins(pinKeys)
        return (true, "Unpinned.")
    }

    func pinOrder(_ keys: [String]) -> (Bool, String) {
        numberPins(keys)
        return (true, "Saved.")
    }

    /// A pin that runs a command in a folder (lazygit in ~/Simplero). It starts when you open it.
    func pinCommand(_ cmd: String, cwd: String?, name: String?) -> (ok: Bool, message: String, key: String?) {
        let command = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return (false, "No command to pin.", nil) }
        let folder = SBPaths.expand(cwd ?? "~")
        let k = "shell:pin-" + UUID().uuidString
        var e = SBEntry(key: k, agent: "shell")
        e.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? command
        e.custom_name = true
        e.pin_cmd = command
        e.pinned = (reg.sessions.values.compactMap(\.pinned).max() ?? -1) + 1
        e.cls = defaultClass(folder)
        e.labels = []
        e.first_seen = now
        e.backend = "ghostty"
        e.cwd = folder
        e.open = false
        e.closed_at = now
        e.closed_reason = "pin"
        e.state = stateOf(e)
        reg.sessions[k] = e
        save()
        return (true, "Pinned.", k)
    }

    /// A pinned shell's terminal: a new one in its folder, running its command. The pin keeps
    /// its row (its key follows the new terminal, like a session whose conversation id changes).
    private func openShellPin(_ k: String, focus: Bool) -> (ok: Bool, message: String, surface: String?) {
        guard var e = reg.sessions[k] else { return (false, "Unknown session.", nil) }
        var folder = SBPaths.expand(e.cwd ?? "~")
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) || !isDir.boolValue { folder = SBPaths.home }
        let input = (e.pin_cmd ?? "").isEmpty ? nil : e.pin_cmd! + "\n"
        guard let made = SessionsAPI.openTab(cwd: folder, input: input, env: [:], focus: focus) else {
            return (false, "Switchboard could not open a terminal.", nil)
        }
        let newKey = "shell:" + made.ws
        reg.sessions.removeValue(forKey: k)
        if newKey != k { e.was = k }
        e.key = newKey
        e.open = true
        e.closed_at = nil
        e.closed_reason = nil
        e.opening_at = nil
        e.backend = "ghostty"
        e.surface_id = made.id
        e.workspace_id = "g:" + made.tab
        e.cwd = folder
        e.working_line = e.pin_cmd ?? ""
        pinStarted[made.id] = now
        e.last_activity = now
        e.last_seen = now
        e.state = stateOf(e)
        reg.sessions[newKey] = e
        save()
        return (true, "Started.", made.id)
    }

    /// When a pin's command was last started (not again while it starts).
    private var pinStarted: [String: Double] = [:]

    /// A pinned shell at its prompt (you quit lazygit): opening the pin starts its command again.
    func startPinCommandIfIdle(_ k: String) {
        guard let e = reg.sessions[k], e.isOpen, e.agent == "shell", e.pinned != nil,
              let cmd = e.pin_cmd, !cmd.isEmpty, let sf = e.surface_id,
              let view = SessionsAPI.surface(id: sf),
              // Only at a prompt with nothing running (the shell is the program in front), and not while it starts.
              SBProcesses.isShell(view.surfaceModel?.foregroundPID ?? 0) || !view.needsConfirmQuit,
              now - (pinStarted[sf] ?? 0) > 5 else { return }
        pinStarted[sf] = now
        update(k) { $0.working_line = cmd }
        _ = SessionsAPI.sendInput(sf, text: cmd, enter: true)
    }

    /// The sessions (tab ids) of the pinned sessions that run: their bells do not count in the Dock.
    func pinnedWorkspaces() -> Set<String> {
        Set(reg.sessions.values.filter { $0.pinned != nil && $0.isOpen }.compactMap { e in
            e.surface_id.flatMap { SessionsAPI.surface(id: $0) }
                .flatMap { BaseTerminalController.controller(owning: $0) as? TerminalController }?.sessionsWorkspace
        })
    }

    /// The first pins, once: the Claude session called “Chief of staff”, and lazygit in the
    /// default folder (when lazygit is installed).
    private func seedPins() {
        let flag = "sessions.pins.seeded"
        guard writable, !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        guard !reg.sessions.values.contains(where: { $0.pinned != nil }) else { return }
        let plain = { (s: String?) in (s ?? "").lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces) }
        if let chief = reg.sessions.values.filter({ $0.agent == "claude" && plain($0.name) == "chief of staff" })
            .max(by: { ($0.last_activity ?? 0) < ($1.last_activity ?? 0) }) {
            update(chief.key) { $0.pinned = 0; $0.parked = false; $0.archived = false }
        }
        let folder = SBPaths.expand(Self.defaultFolder)
        if ["/opt/homebrew/bin/lazygit", "/usr/local/bin/lazygit"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           FileManager.default.fileExists(atPath: folder) {
            _ = pinCommand("lazygit", cwd: folder, name: "lazygit")
        }
    }

    // MARK: Restart for an update

    /// Switchboard is about to restart: remember its sessions, with their other tabs.
    func rememberOpen() -> (Bool, String) {
        let terms = SessionsAPI.terminalList()
        let byID = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [[String: Any]] = []
        for (k, e) in reg.sessions where e.isOpen && e.backend == "ghostty" {
            let t = byID[e.surface_id ?? ""]
            // The session's other tabs (a shell, a server): one new shell each, same folder.
            var tabs: [String] = []
            var seenTabs: Set<String> = [t?.tab ?? ""]
            if let t, !t.ws.isEmpty {
                for o in terms where o.ws == t.ws && !seenTabs.contains(o.tab) {
                    seenTabs.insert(o.tab)
                    tabs.append(o.cwd.isEmpty ? (e.cwd ?? SBPaths.home) : o.cwd)
                }
            }
            items.append(["k": k, "shell": e.agent == "shell", "cwd": (t?.cwd).flatMap { $0.isEmpty ? nil : $0 } ?? e.cwd ?? SBPaths.home,
                          "split": e.split == true, "tabs": tabs])
        }
        // On disk now, not later: the app quits next. If it cannot be saved, it does not quit.
        guard let data = try? JSONSerialization.data(withJSONObject: ["items": items, "at": now]),
              SBFiles.writeAtomic(data, SBPaths.restart) else {
            return (false, "Could not save the list of open sessions in \(SBPaths.data), so Switchboard did not restart.")
        }
        guard saveNow(wait: true) else {
            return (false, "Could not save the session list (\(SBPaths.registry)), so Switchboard did not restart.")
        }
        return (true, "Remembered \(items.count).")
    }

    /// Sessions marked open whose terminal is gone (the app that quit took them along).
    private func markStaleClosed(reason: String) {
        let live = Set(SessionsAPI.terminalList().map(\.id))
        for (k, var e) in reg.sessions where e.isOpen && !live.contains(e.surface_id ?? "") {
            e.open = false
            e.closed_at = now
            e.closed_reason = reason
            e.opening_at = nil
            e.screen = nil
            e.state = stateOf(e)
            reg.sessions[k] = e
        }
    }

    /// After a restart: reopen every session that was open, with its tabs. A list of what
    /// could not be reopened is left next to the saved list.
    func restoreAfterRestart(skipping handedOver: Set<String> = []) async -> (Bool, String) {
        guard let j = SBFiles.readJSON(SBPaths.restart) as? [String: Any],
              now - ((j["at"] as? NSNumber)?.doubleValue ?? 0) <= 600 else { return (true, "Nothing to restore.") }
        // Sessions whose terminals were handed over still run: nothing to reopen.
        let items = ((j["items"] as? [[String: Any]]) ?? []).filter { !handedOver.contains($0["k"] as? String ?? "") }
        markStaleClosed(reason: "restart")
        var n = 0
        var failed: [String] = []
        for it in items {
            let k = it["k"] as? String ?? ""
            let e = reg.sessions[k]
            var ok = false, msg = "", sf: String?
            if let e, e.agent == "shell", e.pinned != nil {
                // A pinned shell: its own row again, running its command (lazygit) again.
                (ok, msg, sf) = openShellPin(e.key, focus: false)
            } else if it["shell"] as? Bool == true || e?.agent == "shell" {
                (ok, msg, sf) = newShell(it["cwd"] as? String, focus: false)
                // The new shell has its own row: it takes the old row's name, class and labels.
                if ok, let e, let sf, reg.sessions[e.key]?.isOpen != true,
                   let newKey = reg.sessions.first(where: { $0.value.surface_id == sf })?.key, newKey != e.key {
                    update(newKey) { x in
                        if e.custom_name == true { x.name = e.name; x.custom_name = true }
                        x.cls = e.cls ?? x.cls
                        x.labels = e.labels ?? x.labels
                        x.was = e.key
                    }
                    reg.sessions.removeValue(forKey: e.key)
                }
            } else if let e, e.isOpen {
                (ok, msg) = (true, "Already open.")
            } else if let e {
                // The Claude of the app that just quit may still be exiting: give it a moment.
                for _ in 0..<20 where runningElsewhere(e.key) != nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                (ok, msg, sf) = openEntry(e.key, focus: false, split: it["split"] as? Bool ?? false)
                if !ok && msg == "No way to resume this session." {
                    // Nothing to resume yet (a new conversation, an agent without an id): start fresh there.
                    (ok, msg, sf) = e.agent == "claude" ? newClaude(e.login_dir ?? "~/.claude", focus: false, cwd: e.cwd)
                                                        : newShell(e.cwd, focus: false)
                }
            } else {
                msg = "It is no longer in the list."
            }
            if ok {
                n += 1
                for cwd in it["tabs"] as? [String] ?? [] {
                    if let sf { _ = SessionsAPI.openTab(cwd: SBPaths.expand(cwd), input: nil, env: [:], focus: false, tabOf: sf) }
                }
            } else {
                failed.append("\(e?.name ?? (k.isEmpty ? (it["cwd"] as? String ?? "?") : k)): \(msg)")
            }
            publish()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? FileManager.default.removeItem(atPath: SBPaths.restart)
        save()
        if !failed.isEmpty {
            SBFiles.writeJSON(["failed": failed, "items": items, "at": now], SBPaths.restart + ".failed")
            return (false, "Reopened \(n). Could not reopen: " + failed.joined(separator: "; "))
        }
        return (true, "Reopened \(n).")
    }
}
