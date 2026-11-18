import Darwin
import Foundation

/// Process facts the session tracker needs, read straight from the kernel
/// (no `ps` or `lsof`): which processes run on a terminal, their arguments and
/// environment, their folder, and the git branch of that folder.
enum SBProcesses {
    /// Every process id on this Mac.
    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let got = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got))).filter { $0 > 0 }
    }

    /// The device number of the controlling terminal of a process, if it has one.
    static func ttyDevice(_ pid: pid_t) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let dev = info.e_tdev
        return dev == UInt32.max || dev == 0 ? nil : dev
    }

    /// The device number of a terminal path such as /dev/ttys012.
    static func deviceOf(ttyPath: String) -> UInt32? {
        guard !ttyPath.isEmpty else { return nil }
        let path = ttyPath.hasPrefix("/dev/") ? ttyPath : "/dev/" + ttyPath
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt32(bitPattern: st.st_rdev)
    }

    /// Arguments and environment of a process (empty for processes we may not read).
    static func argsAndEnv(_ pid: pid_t) -> (args: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        // The executable path, then padding NULs.
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        func next() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        var args: [String] = []
        for _ in 0..<max(0, argc) {
            guard let a = next() else { break }
            args.append(a)
        }
        var env: [String: String] = [:]
        while let e = next(), !e.isEmpty {
            if let eq = e.firstIndex(of: "=") {
                env[String(e[..<eq])] = String(e[e.index(after: eq)...])
            }
        }
        return (args, env)
    }

    /// The working folder of a process.
    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func isAlive(_ pid: Int) -> Bool {
        pid > 0 && (kill(pid_t(pid), 0) == 0 || errno == EPERM)
    }

    /// The branch checked out in a folder (what `git rev-parse --abbrev-ref HEAD` says:
    /// "HEAD" when detached), read from the files; nil outside a git repository.
    static func gitBranch(_ cwd: String?) -> String? {
        guard var dir = cwd, !dir.isEmpty else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }
        while true {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // A worktree or submodule: ".git" is a file that says where the git dir is.
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? p : (dir as NSString).appendingPathComponent(p)
                }
                guard let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst("ref: refs/heads/".count)) }
                if h.hasPrefix("ref: ") { return String(h.dropFirst("ref: ".count)) }
                return "HEAD"
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    static let agents: Set<String> = ["claude", "codex", "opencode", "grok"]

    /// Which coding agent a command line is (claude, codex, opencode, grok), or nil.
    /// One-shot runs (claude -p, codex exec, opencode run, …) are not sessions.
    static func agentKind(_ args: [String]) -> String? {
        guard !args.isEmpty else { return nil }
        var first = (args[0] as NSString).lastPathComponent
        var restStart = 1
        if ["node", "bun", "python3", "python"].contains(first), args.count > 1 {
            first = (args[1] as NSString).lastPathComponent
            restStart = 2
        }
        guard agents.contains(first) else { return nil }
        let rest = args.dropFirst(restStart).prefix(3)
        if first == "claude" && (args.contains("-p") || args.contains(where: { $0.hasPrefix("--print") })) { return nil }
        if first == "codex" && rest.contains(where: { ["exec", "app-server", "mcp", "proto"].contains($0) }) { return nil }
        if first == "opencode" && rest.contains(where: { ["run", "serve", "mcp"].contains($0) }) { return nil }
        return first
    }
}
