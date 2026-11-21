import Foundation

/// The git work tree a session works in, for the panel above its terminal: its branch, how
/// many files and lines it changed (as GitHub counts a pull request: against where the branch
/// left the default branch, with uncommitted and new files), and its dev server.
enum SBWorktree {
    struct Info: Equatable {
        var top: String
        var branch: String
        var files: Int
        var add: Int
        var del: Int
        /// The main checkout on the default branch: its changes are every session's, so no count.
        var shared: Bool
        var server: Server?
    }

    struct Server: Equatable {
        let label: String
        let url: String
        let up: Bool
    }

    /// Prints top=, branch=, shared=, files=, add=, del= for the folder in $1 (nothing outside
    /// git). Runs here and, through the helper, on other machines. Takes no git locks.
    static let script = #"""
cd "$1" 2>/dev/null || exit 0
export GIT_OPTIONAL_LOCKS=0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
def=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
[ -n "$def" ] || def=origin/master
git rev-parse -q --verify "$def" >/dev/null 2>&1 || def=HEAD
base=$(git merge-base HEAD "$def" 2>/dev/null) || base=HEAD
shared=0
if [ "$(git rev-parse --git-dir 2>/dev/null)" = "$(git rev-parse --git-common-dir 2>/dev/null)" ] && [ "$br" = "${def#origin/}" ]; then shared=1; fi
echo "top=$top"; echo "branch=$br"; echo "shared=$shared"
[ "$shared" = 1 ] && exit 0
cd "$top" || exit 0
git diff --numstat "$base" 2>/dev/null | awk '{f++; if ($1 != "-") a += $1; if ($2 != "-") d += $2} END {print "tracked=" f+0; print "add=" a+0; print "del=" d+0}'
git ls-files --others --exclude-standard 2>/dev/null | head -300 | {
  n=0; l=0
  while IFS= read -r f; do
    n=$((n+1))
    if [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 1000000 ] && grep -Iq . "$f"; then l=$((l + $(wc -l < "$f"))); fi
  done
  echo "new=$n"; echo "newlines=$l"
}
"""#

    /// Read the output of `script`.
    static func parse(_ out: String) -> Info? {
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let top = kv["top"], !top.isEmpty else { return nil }
        let n = { (k: String) in Int(kv[k]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0 }
        return Info(top: top, branch: kv["branch"] ?? "", files: n("tracked") + n("new"),
                    add: n("add") + n("newlines"), del: n("del"), shared: kv["shared"] == "1", server: nil)
    }

    /// The work tree of a folder on this Mac, with its dev server (slow: run it off the main thread).
    static func local(_ folder: String, commands: String) -> Info? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "sb-worktree", folder]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard var info = parse(String(decoding: data, as: UTF8.self)) else { return nil }
        info.server = server(for: info.top, commands: commands)
        return info
    }

    // MARK: Dev server (puma-dev)

    /// The Simplero account the dev pages open in.
    static var devAccount: String { UserDefaults.standard.string(forKey: "sessions.devAccount") ?? "calvintest3" }

    /// The dev server of a work tree: the puma-dev link (~/.puma-dev/<name>) that points at it.
    /// A slot (~/Simplero-3, link "3") opens https://<account>.simplero.3.test, the main
    /// checkout (link "simplero") https://<account>.simplero.test. `up`: its Puma runs (puma-dev
    /// starts it at the first request, so the link works either way).
    static func server(for top: String, commands: String) -> Server? {
        let dir = SBPaths.home + "/.puma-dev"
        let fm = FileManager.default
        let real = realPath(top)
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { name in
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: dir + "/" + name) else { return false }
            return realPath(dest.hasPrefix("/") ? dest : dir + "/" + dest) == real
        }
        guard !names.isEmpty else { return nil }
        let up: (String) -> Bool = { n in commands.contains("/.puma-dev/" + n + "/tmp/puma-dev-") }
        var name = names[0]
        if let n = names.first(where: { Int($0) != nil }) { name = n }
        if names.contains("simplero") { name = "simplero" }
        if let n = names.first(where: up) { name = n }
        let url: String, label: String
        if let n = Int(name) {
            url = "https://\(devAccount).simplero.\(n).test/admin?autologin_user=true"
            label = "Slot \(n)"
        } else if name == "simplero" {
            url = "https://\(devAccount).simplero.test/admin?autologin_user=true"
            label = "Main server"
        } else {
            url = "https://\(name).test"
            label = name + ".test"
        }
        return Server(label: label, url: url, up: up(name))
    }

    static func realPath(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(SBPaths.expand(p), &buf) != nil ? String(cString: buf) : SBPaths.expand(p)
    }

    /// Every process's command line (to see which Pumas run), once per look.
    static func commands() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Slots

    /// The slot (~/Simplero-N) each Claude process claimed with simplero-slot, by its process id:
    /// a session that started in ~/Simplero works there.
    static func slotsByOwner() -> [Int: String] {
        let dir = SBPaths.home + "/.cache/simplero-slot"
        var out: [Int: String] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
            let n = String(f.dropLast(5))
            guard Int(n) != nil, let j = SBFiles.readJSON(dir + "/" + f) as? [String: Any],
                  let pid = (j["pid"] as? NSNumber)?.intValue else { continue }
            let path = SBPaths.home + "/Simplero-" + n
            if FileManager.default.fileExists(atPath: path) { out[pid] = path }
        }
        return out
    }
}
