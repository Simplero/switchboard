// Link Router: the default browser that opens every link in the right place.
//
// - Dev and test pages (any *.test or *.internal host, with or without a port;
//   localhost) open in Google Chrome. If the page is already open in a Chrome tab, that
//   tab comes to the front instead of a second copy.
// - claude.ai artifacts open in the Arc Space of the login that published them (the
//   Claude Code hook records it in ~/.config/session-inbox/artifacts.jsonl). An artifact
//   already open in that Space comes to the front.
// - Simplero Docs (doc.simplero.me, /admin/docs/ on simplero.com) open in the main Arc
//   Space: "docs" in arc-spaces.json, else the Space of ~/.claude.
// - Every other link opens in Arc.
//
// x-link-router:background?url=<link> (Switchboard: a test-server link ⌘-clicked in the
// terminal) opens the link the same way, but the browser does not come to the front.
//
// It has no window and no Dock icon, and quits a minute after the last link.
//   Link Router --make-default    ask macOS to make it the default browser
//   Link Router --default-arc     make Arc the default browser again
//   Link Router --dry-run <url>   print where a link would go, open nothing
import AppKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let dataDir = home + "/.config/session-inbox"
let chromeID = "com.google.Chrome"
let arcID = "company.thebrowser.Browser"

enum Target: Equatable {
    case chrome
    case arc(space: String?)
}

/// Where a link goes.
func route(_ url: URL) -> Target {
    let host = (url.host ?? "").lowercased()
    let dev = host.hasSuffix(".test") || host.hasSuffix(".internal")
        || ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    if dev { return .chrome }
    if host == "claude.ai", let id = artifactID(url) {
        return .arc(space: arcSpace(forLogin: loginForArtifact(id)))
    }
    if host == "doc.simplero.me" || ((host == "simplero.com" || host.hasSuffix(".simplero.com")) && url.path.hasPrefix("/admin/docs/")) {
        return .arc(space: arcSpace(forLogin: "docs") ?? arcSpace(forLogin: "~/.claude"))
    }
    return .arc(space: nil)
}

func artifactID(_ url: URL) -> String? {
    let parts = url.path.split(separator: "/").map(String.init)
    if parts.count >= 2, parts[0] == "artifact" { return parts[1] }
    if parts.count >= 3, parts[0] == "code", parts[1] == "artifact" { return parts[2] }
    return nil
}

/// The login that published an artifact: the first hook record (its creation; later
/// records can come from other logins reading or trying to update it), else the first
/// session whose transcript mentions the link.
func loginForArtifact(_ id: String) -> String? {
    guard let text = try? String(contentsOfFile: dataDir + "/artifacts.jsonl", encoding: .utf8) else { return nil }
    var hook: String?, first: String?
    for line in text.split(separator: "\n") where line.contains(id) {
        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              j["id"] as? String == id else { continue }
        let login = j["login_dir"] as? String
        if (j["source"] as? String ?? "hook") == "hook" { if hook == nil { hook = login } } else if first == nil { first = login }
    }
    return hook ?? first
}

/// The Arc Space whose profile is signed in to a login (~/.config/session-inbox/arc-spaces.json).
func arcSpace(forLogin login: String?) -> String? {
    guard let login else { return nil }
    var spaces: [String: String] = [:]
    if let d = FileManager.default.contents(atPath: dataDir + "/arc-spaces.json"),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
        spaces.merge(j) { _, new in new }
    }
    return spaces[login]
}

/// A string safe inside an AppleScript string literal.
func asLiteral(_ s: String) -> String {
    let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    return "\"" + e + "\""
}

/// The same page as Chrome may show it: exactly this URL, and for a bare origin
/// (http://localhost:3000) also with its "/" path. Query and fragment always count.
func variants(_ url: URL) -> [String] {
    let u = url.absoluteString
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.path.isEmpty || c.path == "/" else { return [u] }
    c.path = c.path.isEmpty ? "/" : ""
    return [u] + (c.string.map { [$0] } ?? [])
}

func runScript(_ source: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { NSLog("Link Router: AppleScript error %@", error) }
    return error == nil ? (result?.stringValue ?? "") : nil
}

func appURL(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

func isRunning(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

/// Open in a browser by id; if it is not installed, in Safari. Never through the default
/// browser: that is this app, and the link would come straight back.
func openWith(_ id: String, _ url: URL, background: Bool = false) {
    guard let app = appURL(id) ?? appURL("com.apple.Safari") else { NSLog("Link Router: no browser for %@", url.absoluteString); return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = !background
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
        if let error { NSLog("Link Router: %@", error.localizedDescription) }
    }
}

/// Chrome: bring the tab that already shows this page to the front, else open a new tab.
/// `background`: the same, but Chrome stays behind the app you are in.
func openInChrome(_ url: URL, background: Bool = false) {
    let u = url.absoluteString
    if background, isRunning(chromeID), !u.contains("\""), !u.contains("\\") {
        let targets = "{" + variants(url).map(asLiteral).joined(separator: ", ") + "}"
        let script = """
        tell application id "\(chromeID)"
          set targets to \(targets)
          considering case
            repeat with wi from 1 to count of windows
              set w to window wi
              set wl to URL of every tab of w
              repeat with ti from 1 to count of wl
                if targets contains (item ti of wl) then
                  set active tab index of w to ti
                  return "focused"
                end if
              end repeat
            end repeat
          end considering
          if (count of windows) = 0 then make new window
          tell window 1 to make new tab with properties {URL:\(asLiteral(u))}
          return "opened"
        end tell
        """
        if runScript(script) != nil { return }
    }
    if !background, isRunning(chromeID), !u.contains("\""), !u.contains("\\") {
        let targets = "{" + variants(url).map(asLiteral).joined(separator: ", ") + "}"
        let script = """
        tell application id "\(chromeID)"
          set targets to \(targets)
          considering case
            repeat with wi from 1 to count of windows
              set w to window wi
              set wl to URL of every tab of w
              repeat with ti from 1 to count of wl
                if targets contains (item ti of wl) then
                  set active tab index of w to ti
                  set index of w to 1
                  activate
                  return "focused"
                end if
              end repeat
            end repeat
          end considering
          return "none"
        end tell
        """
        if runScript(script) == "focused" { return }
    }
    openWith(chromeID, url, background: background)
}

/// Arc: in the given Space (its profile is signed in to the right claude.ai account).
/// A tab that already shows the page comes to the front.
func openInArc(_ url: URL, space: String?) {
    let u = url.absoluteString
    guard let space, !u.contains("\""), !u.contains("\\") else { openWith(arcID, url); return }
    let targets = "{" + variants(url).map(asLiteral).joined(separator: ", ") + "}"
    let script = """
    tell application id "\(arcID)"
      if (count of windows) = 0 then make new window
      set w to front window
      set target to missing value
      -- The Space can be in any Arc window.
      repeat with aw in windows
        repeat with s in spaces of aw
          if title of s is \(asLiteral(space)) then
            set target to s
            set w to aw
          end if
        end repeat
        if target is not missing value then exit repeat
      end repeat
      if target is missing value then
        tell w to make new tab with properties {URL:\(asLiteral(u))}
      else
        set found to false
        set targets to \(targets)
        try
          considering case
            repeat with t in tabs of target
              if targets contains (URL of t) then
                tell target to focus
                tell t to select
                set found to true
                exit repeat
              end if
            end repeat
          end considering
        end try
        if not found then
          tell target to make new tab with properties {URL:\(asLiteral(u))}
          tell target to focus
        end if
      end if
      activate
    end tell
    """
    if runScript(script) == nil { openWith(arcID, url) }
}

func open(_ url: URL) {
    if url.scheme?.lowercased() == "x-link-router" {
        // x-link-router:background?url=<link>
        guard let s = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let link = URL(string: s), let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        switch route(link) {
        case .chrome: openInChrome(link, background: true)
        case .arc: openWith(arcID, link, background: true)
        }
        return
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        // A local HTML file or another scheme: Arc shows it.
        openWith(arcID, url)
        return
    }
    switch route(url) {
    case .chrome: openInChrome(url)
    case .arc(let space): openInArc(url, space: space)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitTimer: Timer?

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
        scheduleQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--make-default") {
            // macOS asks you to confirm the change.
            for scheme in ["http", "https"] {
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { error in
                    if let error { NSLog("Link Router: %@", error.localizedDescription) }
                }
            }
        } else if args.contains("--default-arc"), let arc = appURL(arcID) {
            for scheme in ["http", "https"] {
                NSWorkspace.shared.setDefaultApplication(at: arc, toOpenURLsWithScheme: scheme) { _ in }
            }
        }
        scheduleQuit()
    }

    private func scheduleQuit() {
        quitTimer?.invalidate()
        quitTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in NSApp.terminate(nil) }
    }
}

// --dry-run <url>: print the route only.
if let i = CommandLine.arguments.firstIndex(of: "--dry-run"), i + 1 < CommandLine.arguments.count,
   let url = URL(string: CommandLine.arguments[i + 1]) {
    switch route(url) {
    case .chrome: print("chrome")
    case .arc(let space): print("arc" + (space.map { " space=\($0)" } ?? ""))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
