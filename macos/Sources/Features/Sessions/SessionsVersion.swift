import AppKit
import SwiftUI

/// Which build of Ghostty Sessions is running, and whether a newer one is installed.
///
/// install-sessions-app.sh writes `SessionsBuild` (commit count) and
/// `SessionsCommit` into the installed app's Info.plist. The running app keeps
/// the values it started with; it re-reads the Info.plist on disk every few
/// seconds, so a newer install shows an "Update" button.
@MainActor
final class SessionsVersion: ObservableObject {
    static let shared = SessionsVersion()

    let runningBuild: Int
    let runningCommit: String
    @Published var installedBuild: Int
    @Published var installedCommit: String

    private var timer: Timer?

    var updateAvailable: Bool { installedBuild > runningBuild }
    var label: String { "Ghostty Sessions b\(runningBuild)" }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        runningBuild = Int(info["SessionsBuild"] as? String ?? "") ?? 0
        runningCommit = info["SessionsCommit"] as? String ?? ""
        installedBuild = runningBuild
        installedCommit = runningCommit
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return }
        let b = Int(dict["SessionsBuild"] as? String ?? "") ?? 0
        let c = dict["SessionsCommit"] as? String ?? ""
        if b != installedBuild { installedBuild = b }
        if c != installedCommit { installedCommit = c }
    }

    /// Quit and start the newly installed build. The session helper remembers
    /// which sessions were open here and reopens them after the restart.
    func restart() {
        let open = SessionsStore.shared.payload?.s.filter { $0.isOpen && $0.be == "ghostty" }.count ?? 0
        let alert = NSAlert()
        alert.messageText = "Restart Ghostty Sessions to update to b\(installedBuild)?"
        alert.informativeText = open == 0
            ? "No sessions are open here."
            : "\(open) session\(open == 1 ? "" : "s") open here will close and reopen with the same conversation and login after the restart. A session that is working right now stops its current step."
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SessionsStore.shared.send(["op": "remember_open"])
        let path = Bundle.main.bundleURL.path
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"\(path)\""]
        try? relaunch.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UserDefaults.standard.set(true, forKey: "sessions.restoreAfterRestart")
            NSApp.terminate(nil)
        }
    }
}

private let selectedBlueTitle = Color(red: 0.36, green: 0.52, blue: 1.0)

/// Shown at the right end of every window's title bar: name, build, and an
/// Update button when a newer build is installed.
struct SessionsTitlebarBadge: View {
    @ObservedObject var version = SessionsVersion.shared
    @AppStorage("sessions.sidebar.web") private var web = true

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button { web.toggle() } label: {
                Text(web ? "Sidebar: web" : "Sidebar: native")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().stroke(Color.gray.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .help("Switch between the web sidebar and the native sidebar")
            Text(version.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Commit \(version.runningCommit)")
            if version.updateAvailable {
                Text("update ready").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(selectedBlueTitle)
            }
        }
        .padding(.trailing, 10)
        .frame(width: 420, height: 28, alignment: .trailing)
    }
}

extension NSWindow {
    /// Add the name/version badge to the title bar once.
    @MainActor
    func addSessionsBadge() {
        let id = NSUserInterfaceItemIdentifier("sessions.badge")
        guard !titlebarAccessoryViewControllers.contains(where: { $0.identifier == id }) else { return }
        let host = NSHostingView(rootView: SessionsTitlebarBadge())
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
        let vc = NSTitlebarAccessoryViewController()
        vc.identifier = id
        vc.view = host
        vc.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(vc)
    }
}
