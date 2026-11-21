import Foundation

/// Other machines that run Claude sessions for you (a Linux box): an ssh host each,
/// listed in machines.json in Switchboard's data folder:
///
///     {"machines": [{"name": "devbox"}]}
///
/// Claude runs on that machine, next to its files, in a tmux session that outlives the
/// connection: it keeps working when the Mac sleeps, loses the network or restarts
/// Switchboard. One of Switchboard's terminals shows it over ssh, so reading its screen,
/// typing and the sidebar work as for a session here. Its conversation comes back to the
/// Mac when both sync their projects folder (Syncthing), so names, summaries,
/// links and search work too.
///
/// Switchboard installs a small helper there (~/.local/bin/switchboard-remote) that starts,
/// attaches to and stops those tmux sessions. Optional keys for checks: "ssh" (the host, if
/// not the name), "claude" (a stand-in program), "tmux" (the tmux server's name).
enum SBMachines {
    struct Machine: Codable, Equatable {
        let name: String
        var ssh: String? = nil
        var claude: String? = nil
        var tmux: String? = nil
        var host: String { ssh ?? name }
    }

    static var path: String { SBPaths.data + "/machines.json" }

    private static var cache: (mtime: Double, list: [Machine]) = (-1, [])
    static var all: [Machine] {
        let m = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if m != cache.mtime {
            struct File: Codable { let machines: [Machine] }
            let list = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(File.self, from: $0) }?.machines ?? []
            cache = (m, list.filter { !$0.name.isEmpty && $0.name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil })
        }
        return cache.list
    }

    static func named(_ n: String?) -> Machine? { n.flatMap { n in all.first { $0.name == n } } }

    // MARK: Talking to a machine

    /// What the last look at each machine found (for the new-session form).
    struct Status { var ok: Bool; var message: String; var at: Double; var home: String? }
    @MainActor static var status: [String: Status] = [:]
    /// The helper is up to date there (this run of Switchboard put it there, or saw it).
    @MainActor private static var installed = Set<String>()

    /// Run a command there (no terminal), with `input` on its stdin.
    static func run(_ m: Machine, _ remote: String, input: Data? = nil, timeout: Double = 25) async -> (status: Int32, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ControlPath=none", m.host, "--", remote]
                let out = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = out
                p.standardInput = input == nil ? FileHandle.nullDevice : inp
                do { try p.run() } catch { cont.resume(returning: (-1, "ssh did not start: \(error.localizedDescription)")); return }
                if let input {
                    DispatchQueue.global().async {
                        try? inp.fileHandleForWriting.write(contentsOf: input)
                        try? inp.fileHandleForWriting.close()
                    }
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Make sure the machine answers and has the current helper. Remembers what it found.
    @MainActor
    static func prepare(_ m: Machine, force: Bool = false) async -> Status {
        if !force, installed.contains(m.name), let s = status[m.name], s.ok, Date().timeIntervalSince1970 - s.at < 120 { return s }
        let script = helper.replacingOccurrences(of: "__VERSION__", with: String(helperVersion))
        // Install only when the version there differs; print the home folder either way.
        let remote = "v=$(.local/bin/switchboard-remote version 2>/dev/null); "
            + "if [ \"$v\" != \(helperVersion) ]; then mkdir -p .local/bin && cat > .local/bin/switchboard-remote.new "
            + "&& chmod +x .local/bin/switchboard-remote.new && mv .local/bin/switchboard-remote.new .local/bin/switchboard-remote; "
            + "else cat >/dev/null; fi; command -v tmux >/dev/null || echo NO-TMUX; echo \"HOME=$HOME\""
        let r = await run(m, remote, input: Data(script.utf8))
        let home = r.out.split(separator: "\n").last(where: { $0.hasPrefix("HOME=") }).map { String($0.dropFirst(5)) }
        var s: Status
        if r.status == 0, r.out.contains("NO-TMUX") {
            s = Status(ok: false, message: "\(m.name) has no tmux. Install it there (sudo pacman -S tmux).", at: Date().timeIntervalSince1970, home: home)
        } else if r.status == 0, home != nil {
            s = Status(ok: true, message: "", at: Date().timeIntervalSince1970, home: home)
            installed.insert(m.name)
        } else {
            let why = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "no answer"
            s = Status(ok: false, message: "\(m.name) does not answer over ssh (\(why)).", at: Date().timeIntervalSince1970, home: nil)
        }
        status[m.name] = s
        return s
    }

    /// Put a file there, in the helper's folder (~/.cache/switchboard/<name>). Returns its path there.
    static func upload(_ m: Machine, _ data: Data, name: String, home: String) async -> String? {
        let dir = ".cache/switchboard/" + (name as NSString).deletingLastPathComponent
        let r = await run(m, "mkdir -p \(shq(dir)) && cat > \(shq(".cache/switchboard/" + name))", input: data, timeout: 60)
        return r.status == 0 ? home + "/.cache/switchboard/" + name : nil
    }

    /// End a session's Claude there (its conversation stays).
    static func stop(_ m: Machine, sid: String) async {
        _ = await run(m, envPrefix(m) + ".local/bin/switchboard-remote stop \(sid)")
    }

    /// The conversations that run there now (also with no terminal of Switchboard on them).
    static func running(_ m: Machine) async -> Set<String>? {
        let r = await run(m, envPrefix(m) + ".local/bin/switchboard-remote list", timeout: 12)
        guard r.status == 0 else { return nil }
        return Set(r.out.split(separator: "\n").compactMap { l in
            let id = l.split(separator: " ").first.map(String.init) ?? ""
            return SBBackground.isUUID(id) ? id : nil
        })
    }

    private static func envPrefix(_ m: Machine) -> String {
        var s = ""
        if let c = m.claude { s += "SWITCHBOARD_CLAUDE_BIN=\(shq(c)) " }
        if let t = m.tmux { s += "SWITCHBOARD_TMUX=\(shq(t)) " }
        return s
    }

    /// Quoted for a shell, always (so ~ stays ~ until the helper expands it there).
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// What a terminal here runs to show the session: ssh to the machine, attach to the session
    /// (or start it: `new` with this id, `resume` an existing conversation). When the connection
    /// drops it connects again; when Claude ends, it ends.
    static func attachCommand(_ m: Machine, sid: String, login: String, folder: String, mode: String, first: String? = nil) -> String {
        var remote = envPrefix(m) + ".local/bin/switchboard-remote attach \(sid) \(shq(login)) \(shq(folder)) \(mode)"
        if let first { remote += " " + shq(first) }
        // /usr/bin/ssh, not "ssh": Ghostty's shell integration wraps that name (terminfo setup),
        // which hid the session. The helper there picks a terminal type it knows.
        let ssh = "/usr/bin/ssh -tt -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o ControlPath=none \(shq(m.host)) -- \(shq(remote))"
        let again = "printf '\\n\\033[2mLost the connection to \(m.name). Connecting again in 5 s…\\033[0m\\n'"
        return "while :; do \(ssh); r=$?; [ $r -eq 255 ] || break; \(again); sleep 5; done"
    }

    /// An ssh process that shows a session of a machine: its host and what it attaches to.
    struct Attached { let host: String; let sid: String; let login: String; let folder: String }

    static func parseAttach(_ args: [String]) -> Attached? {
        guard let first = args.first, (first as NSString).lastPathComponent == "ssh",
              let ri = args.lastIndex(where: { $0.contains("switchboard-remote attach ") }), ri >= 2, args[ri - 1] == "--" else { return nil }
        let words = shellWords(args[ri])
        guard let ai = words.firstIndex(of: "attach"), words.count >= ai + 5, SBBackground.isUUID(words[ai + 1]) else { return nil }
        return Attached(host: args[ri - 2], sid: words[ai + 1], login: words[ai + 2], folder: words[ai + 3])
    }

    /// Split a command line the way a shell does ('…', "…", \x), without expanding anything.
    static func shellWords(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inWord = false
        var quote: Character? = nil
        var it = s.makeIterator()
        while let c = it.next() {
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"", let n = it.next() { cur.append(n) } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; inWord = true
            } else if c == "\\" {
                if let n = it.next() { cur.append(n) }; inWord = true
            } else if c == " " || c == "\t" || c == "\n" {
                if inWord { out.append(cur); cur = ""; inWord = false }
            } else {
                cur.append(c); inWord = true
            }
        }
        if inWord { out.append(cur) }
        return out
    }

    // MARK: The helper on the machine

    static let helperVersion = 5

    static let helper = #"""
#!/usr/bin/env bash
# switchboard-remote: Switchboard on your Mac runs Claude sessions on this machine through
# this file. Switchboard installs it and calls it over ssh; you do not need to run it.
# Each session is a tmux session "sb-<conversation id>" on its own tmux server
# (tmux -L switchboard), so Claude keeps working when the Mac sleeps, loses the
# connection or restarts Switchboard. Switchboard's terminal attaches to it.
#   switchboard-remote attach <id> <login dir> <folder> new|resume [first-message file]
#   switchboard-remote stop <id>      end that Claude (its conversation stays)
#   switchboard-remote list           the sessions that run: <id> <last activity>
set -u
VERSION=__VERSION__
SOCK="${SWITCHBOARD_TMUX:-switchboard}"
STATE="$HOME/.cache/switchboard"
CONF="$STATE/tmux.conf"
CLAUDE_BIN="${SWITCHBOARD_CLAUDE_BIN:-claude}"
mkdir -p "$STATE"
cat > "$CONF" <<'CONF'
# Written by switchboard-remote. tmux only keeps the session alive: no status line, no
# prefix key (Ctrl+B stays Claude's), the wheel scrolls back, a selection is copied to
# the Mac's clipboard, and Claude's title and focus reach Switchboard.
set -g prefix None
set -g prefix2 None
set -g status off
set -g mouse on
set -g history-limit 100000
# Not 0: an arrow key split over the network must never read as Escape (Claude stops on Escape).
set -s escape-time 25
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-ghostty:RGB:extkeys:clipboard:title,xterm-256color:RGB"
set -s extended-keys on
set -s extended-keys-format csi-u
set -g allow-passthrough on
set -s set-clipboard on
set -g focus-events on
set -g set-titles on
set -g set-titles-string "#{pane_title}"
set -g allow-rename on
set -g detach-on-destroy on
set -g destroy-unattached off
set -g remain-on-exit off
CONF
# A shell run by ssh may have no locale: say UTF-8, or tmux draws ❯ and ⏺ as "_".
export LANG="${LANG:-C.UTF-8}"
t() { tmux -u -L "$SOCK" -f "$CONF" "$@"; }
expand() { case "$1" in "~") echo "$HOME" ;; "~/"*) echo "$HOME/${1#\~/}" ;; *) echo "$1" ;; esac; }
alive() { t has-session -t "=sb-$1" 2>/dev/null; }
gone() { for _ in $(seq 1 40); do pgrep -f -- "(--resume|--session-id) $1" >/dev/null || return 0; sleep 0.25; done; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
version) echo "$VERSION" ;;
list) t list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null | sed -n 's/^sb-//p' ;;
stop)
  id="$1"
  alive "$id" && t kill-session -t "=sb-$id"
  gone "$id"
  rm -f "$STATE/run-$id.sh" ;;
attach)
  id="$1"; login="$2"; dir="$3"; mode="$4"; first="${5:-}"
  name="sb-$id"
  if alive "$id"; then
    if [ "$(t show-environment -t "=$name" SB_LOGIN 2>/dev/null)" = "SB_LOGIN=$login" ]; then
      infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color
      exec tmux -u -L "$SOCK" -f "$CONF" attach-session -t "=$name"
    fi
    # Another login now (Switch login): end this Claude, resume the conversation with the new one.
    t kill-session -t "=$name"; mode=resume
  fi
  gone "$id"
  folder="$(expand "$dir")"
  infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color
  if [ ! -d "$folder" ]; then echo "There is no folder $dir on $(hostname)."; exit 3; fi
  run="$STATE/run-$id.sh"
  {
    echo '#!/usr/bin/env bash'
    printf 'cd %q || exit 1\n' "$folder"
    if [ "$login" = "~/.claude" ]; then echo 'unset CLAUDE_CONFIG_DIR'; else printf 'export CLAUDE_CONFIG_DIR=%q\n' "$(expand "$login")"; fi
    echo 'unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT'
    flag=--resume; [ "$mode" = new ] && flag=--session-id
    if [ -n "$first" ] && [ -f "$first" ]; then
      printf 'm=$(cat %q); rm -f %q\n' "$first" "$first"
      printf 'exec %q %s %s --dangerously-skip-permissions "$m"\n' "$CLAUDE_BIN" "$flag" "$id"
    else
      printf 'exec %q %s %s --dangerously-skip-permissions\n' "$CLAUDE_BIN" "$flag" "$id"
    fi
  } > "$run"
  chmod +x "$run"
  exec tmux -u -L "$SOCK" -f "$CONF" new-session -s "$name" -e "SB_LOGIN=$login" "bash -l $(printf %q "$run")" ;;
*) echo "usage: switchboard-remote attach|stop|list|version"; exit 2 ;;
esac
"""#
}
