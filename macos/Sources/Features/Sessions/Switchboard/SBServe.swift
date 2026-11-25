import CryptoKit
import Foundation

/// The phone's way in on another machine, for when this Mac is closed or asleep.
///
/// Switchboard installs a small server on each machine (switchboard-serve.py from the app,
/// run there as a systemd user service). It speaks the phone's protocol (SBRemote), reports
/// itself to Simplero like a Mac, and shows the Claude sessions that run there in tmux.
///
/// Every 30 s this Mac writes rows.json there: its rows for that machine's sessions (names,
/// summaries) and its logins and folders. While rows.json is fresh, the Mac is up and shows
/// those sessions itself, so the server there lists none of them (no session twice on the phone).
/// Sessions the phone started there while the Mac was away come into the sidebar here.
@MainActor
enum SBServe {
    /// What was installed there in this run of Switchboard (by machine): the hash of the files.
    private static var installed: [String: String] = [:]
    private static var rowsSent: [String: (data: Data, at: Double)] = [:]

    static let env = ProcessInfo.processInfo.environment
    /// A test copy signs the server in with a test key instead of Simplero (SWITCHBOARD_SERVE_TESTKEY).
    static var testKey: String? { env["SWITCHBOARD_SERVE_TESTKEY"].flatMap { $0.isEmpty ? nil : $0 } }

    /// The service and its files, apart for a test machine entry (its own tmux server).
    static func suffix(_ m: SBMachines.Machine) -> String { m.tmux.map { "-" + $0 } ?? "" }
    static func unit(_ m: SBMachines.Machine) -> String { "switchboard-serve\(suffix(m))" }
    static func confPath(_ m: SBMachines.Machine) -> String { ".config/switchboard/serve\(suffix(m)).json" }
    static func stateDir(_ m: SBMachines.Machine, home: String) -> String { home + "/.cache/switchboard" + (m.tmux.map { "/" + $0 } ?? "") }

    static var script: Data? {
        Bundle.main.url(forResource: "switchboard-serve", withExtension: "py").flatMap { try? Data(contentsOf: $0) }
    }

    /// Each look at the machines (every 30 s): install or update the server there, then the rows.
    static func sync(_ m: SBMachines.Machine, home: String) async {
        guard m.serve != false else { return }
        guard let key = SBAccount.shared.currentKey ?? testKey,
              let owner = SBRemote.readOwner() ?? SBAccount.shared.person else { return }
        await install(m, home: home, key: key, owner: owner)
        await sendRows(m, home: home)
    }

    private static func install(_ m: SBMachines.Machine, home: String, key: String, owner: SBRemote.Person) async {
        guard let script else { return }
        var conf: [String: Any] = [
            "key": key, "server": SBAccount.server, "owner": ["id": owner.id, "name": owner.name, "server": owner.server],
            "name": m.name, "port": m.serve_port ?? 4480, "tmux": m.tmux ?? "switchboard", "state": stateDir(m, home: home),
            "build": SessionsVersion.shared.runningBuild,
            "logins": SBLogins.dirs.map { ["d": $0, "lg": SBLogins.short($0), "email": SBLogins.email($0)] },
        ]
        if let c = m.claude { conf["claude"] = c }
        if let p = m.projects { conf["projects"] = [p] }
        if let t = testKey {
            conf["test_key_sha256"] = SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
            conf["report"] = false
        }
        guard let confData = try? JSONSerialization.data(withJSONObject: conf, options: [.sortedKeys, .prettyPrinted]) else { return }
        let unitText = """
        [Unit]
        Description=Switchboard for the iPhone app: the Claude sessions on this machine
        After=network-online.target

        [Service]
        ExecStart=/usr/bin/env python3 %h/.local/bin/switchboard-serve %h/\(confPath(m))
        Restart=always
        RestartSec=10

        [Install]
        WantedBy=default.target

        """
        let unitData = Data(unitText.utf8)
        let hash = SHA256.hash(data: script + confData + unitData).map { String(format: "%02x", $0) }.joined()
        if installed[m.name] == hash { return }
        let unitFile = ".config/systemd/user/\(unit(m)).service"
        for (data, path) in [(script, ".local/bin/switchboard-serve.new"), (confData, confPath(m) + ".new"), (unitData, unitFile + ".new")] {
            guard await SBMachines.put(m, data, to: path) else { return }
        }
        // Only what changed is replaced; the service restarts only then (a phone's connection drops once).
        let q = SBMachines.shq
        let remote = "set -e; changed=0; chmod 700 .local/bin/switchboard-serve.new; chmod 600 \(q(confPath(m) + ".new")); "
            + "for f in .local/bin/switchboard-serve \(q(confPath(m))) \(q(unitFile)); do "
            + "if cmp -s \"$f.new\" \"$f\"; then rm -f \"$f.new\"; else mv \"$f.new\" \"$f\"; changed=1; fi; done; "
            + "systemctl --user daemon-reload; systemctl --user enable \(unit(m)) >/dev/null 2>&1; "
            + "if [ $changed = 1 ]; then systemctl --user restart \(unit(m)); else systemctl --user start \(unit(m)); fi; "
            + "echo OK changed=$changed"
        let r = await SBMachines.run(m, remote, timeout: 30)
        if r.out.contains("OK") {
            installed[m.name] = hash
            if r.out.contains("changed=1") { SessionSwitchLog.did("the phone's server on \(m.name) is installed or updated") }
        }
    }

    /// This Mac's rows for the sessions on `m`, with when (so the server there knows the Mac is up).
    private static func sendRows(_ m: SBMachines.Machine, home: String) async {
        let p = Switchboard.shared.payloadObject()
        let rows = ((p["s"] as? [[String: Any]]) ?? []).filter { $0["m"] as? String == m.name && $0["ar"] as? Bool != true }
        let body: [String: Any] = [
            "rows": rows, "folders": Switchboard.shared.usualFolders(),
            "logins": SBLogins.dirs.map { ["d": $0, "lg": SBLogins.short($0), "email": SBLogins.email($0)] },
        ]
        guard let content = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let now = Date().timeIntervalSince1970
        var full = body
        full["at"] = Int(now)
        guard let data = try? JSONSerialization.data(withJSONObject: full, options: [.sortedKeys]) else { return }
        // Unchanged rows still go every minute: that is how the server knows this Mac is up.
        if let last = rowsSent[m.name], last.data == content, now - last.at < 55 { return }
        if await SBMachines.put(m, data, to: stateDir(m, home: home) + "/rows.json") { rowsSent[m.name] = (content, now) }
    }

    /// The sessions the phone started on `m` (the server's started.json) that run there now.
    static func startedThere(_ m: SBMachines.Machine, home: String) async -> [String: [String: Any]] {
        guard m.serve != false, let d = await SBMachines.fetch(m, stateDir(m, home: home) + "/started.json", timeout: 15),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { return [:] }
        return j
    }
}
