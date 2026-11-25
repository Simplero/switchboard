import Foundation

/// The pull requests of the open sessions, from GitHub (`gh`): the one of the session's branch,
/// and the ones its brief links to. The panel and In this session show their steps
/// (PR, CI, merged) from them. Looked at every 2 minutes, a few at a time, off the main thread.
enum SBPRs {
    struct PR: Equatable {
        let number: Int
        let url: String
        /// "OPEN", "MERGED" or "CLOSED".
        let state: String
        /// "pass", "fail", "pending" or "none".
        let ci: String
        let mergedAt: String?
        let title: String

        var json: [String: Any] {
            ["n": number, "u": url, "s": state, "ci": ci, "ma": mergedAt ?? "", "t": title]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byKey: [String: (pr: PR?, at: Double)] = [:]
    nonisolated(unsafe) private static var origins: [String: String?] = [:]
    nonisolated(unsafe) private static var running = false

    static let gh: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// "owner/repo" of a GitHub address.
    static func slug(_ url: String) -> String? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.hasSuffix(".git") { u.removeLast(4) }
        guard let r = u.range(of: "github.com") else { return nil }
        let rest = u[r.upperBound...].drop { $0 == "/" || $0 == ":" }
        let parts = rest.split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    /// A pull request address: its repository and number.
    static func parsePR(_ url: String) -> (slug: String, number: Int)? {
        guard let s = slug(url), let r = url.range(of: "/pull/") else { return nil }
        let n = url[r.upperBound...].prefix { $0.isNumber }
        return Int(n).map { (s, $0) }
    }

    static func branchKey(_ slug: String, _ branch: String) -> String { "b|\(slug)|\(branch)" }
    static func prKey(_ slug: String, _ number: Int) -> String { "p|\(slug)|\(number)" }

    static func cached(_ key: String) -> PR? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]?.pr ?? nil
    }

    /// The GitHub repository of a work tree here (cached).
    static func repo(of top: String) -> String? {
        lock.lock()
        if let hit = origins[top] { lock.unlock(); return hit }
        lock.unlock()
        let out = SBBackground.run("/usr/bin/git", ["-C", top, "remote", "get-url", "origin"], timeout: 5)
        let s = out.flatMap { $0.code == 0 ? slug($0.out) : nil }
        lock.lock(); origins[top] = s; lock.unlock()
        return s
    }

    /// Look again at what is older than 2 minutes (open ones) or 30 minutes (merged, closed).
    static func refresh(_ keys: [String]) {
        lock.lock()
        if running { lock.unlock(); return }
        let now = Date().timeIntervalSince1970
        let due = keys.filter { k in
            guard let hit = byKey[k] else { return true }
            let done = hit.pr.map { $0.state != "OPEN" } ?? false
            return now - hit.at > (done ? 1800 : 120)
        }
        guard !due.isEmpty, gh != nil else { lock.unlock(); return }
        running = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            for k in due.prefix(12) {
                let pr = look(k)
                lock.lock(); byKey[k] = (pr, Date().timeIntervalSince1970); lock.unlock()
            }
            lock.lock(); running = false; lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { Switchboard.shared.publish() } }
        }
    }

    private static let fields = "number,url,state,mergedAt,title,statusCheckRollup"

    private static func look(_ key: String) -> PR? {
        guard let gh else { return nil }
        let p = key.split(separator: "|", maxSplits: 2).map(String.init)
        guard p.count == 3 else { return nil }
        let args: [String]
        if p[0] == "b" {
            args = ["pr", "list", "--repo", p[1], "--head", p[2], "--state", "all", "--limit", "1", "--json", fields]
        } else {
            args = ["pr", "view", p[2], "--repo", p[1], "--json", fields]
        }
        guard let r = SBBackground.run(gh, args, timeout: 20), r.code == 0,
              let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) else { return nil }
        let o: [String: Any]? = (j as? [[String: Any]])?.first ?? (j as? [String: Any])
        guard let o, let n = (o["number"] as? NSNumber)?.intValue, let url = o["url"] as? String else { return nil }
        var ci = "none"
        let checks = (o["statusCheckRollup"] as? [[String: Any]]) ?? []
        if !checks.isEmpty {
            let states = checks.map { (($0["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ($0["state"] as? String) ?? $0["status"] as? String ?? "").uppercased() }
            if states.contains(where: { ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"].contains($0) }) { ci = "fail" }
            else if states.contains(where: { ["PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED", "WAITING", ""].contains($0) }) { ci = "pending" }
            else { ci = "pass" }
        }
        return PR(number: n, url: url, state: o["state"] as? String ?? "OPEN", ci: ci,
                  mergedAt: (o["mergedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 }, title: o["title"] as? String ?? "")
    }
}
