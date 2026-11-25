import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

/// This Mac's Simplero sign-in, for the Switchboard iPhone app.
///
/// - Sign in goes through the browser like the phone (OAuth code + PKCE, the public client
///   `simplero-switchboard-app`), and gives the person's mobile API key, kept in the Keychain.
/// - Signed in, this Mac tells Simplero every 2 minutes that it runs Switchboard, with its
///   Tailscale address and port (PUT /api/mobile/v1/switchboard/machines/<this Mac's id>). The
///   phone gets the list of the person's Macs from Simplero and connects to each over Tailscale.
/// - The signed-in person owns this Mac's phone link (SBRemote lets in only their phones).
/// - SWITCHBOARD_REMOTE_SIMPLERO=https://simplero.test signs a test copy in to the development server.
@MainActor
final class SBAccount: NSObject, ObservableObject {
    static let shared = SBAccount()

    struct Machine: Identifiable, Equatable {
        let id: String
        let name: String
        let online: Bool
        let lastSeen: Date?
        let address: String
    }

    @Published private(set) var person: SBRemote.Person?
    @Published private(set) var signingIn = false
    @Published private(set) var problem: String?
    @Published private(set) var machines: [Machine] = []
    @Published private(set) var lastReport: Date?

    private var apiKey: String?
    /// The mobile API key, for the phone's server on another machine (SBServe).
    var currentKey: String? { apiKey }
    private var timer: Timer?
    private var authSession: ASWebAuthenticationSession?

    static let clientID = "simplero-switchboard-app"
    static let callbackScheme = "simpleroswitchboard"
    static let redirectURI = "simpleroswitchboard://oauth"
    static let every: TimeInterval = 120

    /// simplero.com, or the development server for a test copy.
    static let server: String = {
        let dev = ProcessInfo.processInfo.environment["SWITCHBOARD_REMOTE_SIMPLERO"] ?? ""
        return (dev.isEmpty ? "https://simplero.com" : dev).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }()
    static var secureHost: String {
        server.hasSuffix(".test") ? "https://secure.simplero.test" : "https://secure.simplero.com"
    }

    /// This Mac's own id in Simplero's list, made once.
    static let machineID: String = {
        let file = SBPaths.data + "/machine-id"
        if let s = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        let id = UUID().uuidString.lowercased()
        _ = SBFiles.writeAtomic(Data(id.utf8), file)
        return id
    }()

    var signedIn: Bool { apiKey != nil }
    /// The mobile key, for Simplero calls made for you (the page pane's sign-in link).
    var mobileKey: String? { apiKey }

    // MARK: Start

    func start() {
        apiKey = Keychain.read(Self.server)
        // A test copy signs in with a development key, without the browser (never stored).
        if apiKey == nil, let k = ProcessInfo.processInfo.environment["SWITCHBOARD_SIMPLERO_KEY"], !k.isEmpty { apiKey = k }
        guard apiKey != nil else { return }
        Task { await refreshPerson(); await report() }
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { _ in
            Task { @MainActor in await SBAccount.shared.report() }
        }
    }

    // MARK: Sign in and out

    func signIn() {
        guard !signingIn else { return }
        problem = nil
        let verifier = Self.randomString()
        let state = Self.randomString()
        var c = URLComponents(string: Self.secureHost + "/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "mobile_app"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = c.url else { return }
        signingIn = true
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
            Task { @MainActor in
                let me = SBAccount.shared
                me.authSession = nil
                guard let callback else {
                    me.signingIn = false
                    if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { return }
                    me.problem = "The sign-in did not finish. Try again."
                    return
                }
                await me.finish(callback: callback, state: state, verifier: verifier)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false   // your browser's Simplero login, passkeys and 2FA
        authSession = session
        if !session.start() {
            signingIn = false
            authSession = nil
            problem = "Could not open the sign-in page."
        }
    }

    private func finish(callback: URL, state: String, verifier: String) async {
        defer { signingIn = false }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else { problem = "That sign-in was for another attempt. Try again."; return }
        guard let code = value("code"), !code.isEmpty else { problem = "Simplero did not sign you in."; return }
        do {
            var token = URLRequest(url: URL(string: Self.secureHost + "/oauth/token")!)
            token.httpMethod = "POST"
            token.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            token.httpBody = Data(Self.form(["grant_type": "authorization_code", "code": code, "client_id": Self.clientID,
                                             "redirect_uri": Self.redirectURI, "code_verifier": verifier]).utf8)
            guard let access = try await Self.json(token)["access_token"] as? String else { throw Failure.answer }
            var exchange = URLRequest(url: URL(string: Self.server + "/api/mobile/v1/auth/oauth")!)
            exchange.httpMethod = "POST"
            exchange.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            exchange.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let key = try await Self.json(exchange)["api_key"] as? String, !key.isEmpty else { throw Failure.answer }
            guard case .person(let p) = await SBRemote.whoIs(key: key, server: Self.server) else { throw Failure.answer }
            Keychain.save(key, Self.server)
            apiKey = key
            person = p
            // The signed-in person owns this Mac's phone link from now on.
            SBRemote.writeOwner(p)
            // Pages that waited on Simplero's login come now.
            for page in SessionsDocPanes.shared.pages.values { page.signedInNow() }
            startTimer()
            await report()
        } catch {
            problem = "Simplero did not finish the sign-in. Try again."
        }
    }

    func signOut() {
        let key = apiKey
        Keychain.delete(Self.server)
        apiKey = nil
        person = nil
        machines = []
        lastReport = nil
        timer?.invalidate()
        timer = nil
        // Off the phone's list.
        if let key {
            var req = Self.request("switchboard/machines/\(Self.machineID)", key: key)
            req.httpMethod = "DELETE"
            Task { _ = try? await URLSession.shared.data(for: req) }
        }
    }

    // MARK: Reporting this Mac

    /// Tell Simplero this Mac runs Switchboard, and where the phone finds it; then read the list.
    func report() async {
        guard let key = apiKey else { return }
        let ts = await Task.detached(priority: .utility) { Self.tailscaleSelf() }.value
        // The name you gave the Mac in Tailscale (calvins-mbp-16-m5), else its computer name.
        let tsName = ts.dnsName.flatMap { $0.split(separator: ".").first.map(String.init) }
        var body: [String: Any] = ["name": tsName ?? ts.host ?? (Host.current().localizedName ?? "Mac"),
                                   "port": Int(SBRemote.port), "app_build": SessionsVersion.shared.runningBuild]
        if let ip = ts.ip { body["tailscale_ip"] = ip }
        if let name = ts.dnsName { body["tailscale_name"] = name }
        var req = Self.request("switchboard/machines/\(Self.machineID)", key: key)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                problem = "Simplero no longer accepts this Mac's sign-in. Sign in again."
                return
            }
            if status == 404 {
                problem = "Simplero cannot list your Macs yet (its update is not live). The phone still connects by the Mac's name."
                return
            }
            if (200..<300).contains(status) { lastReport = Date(); problem = nil }
        } catch {
            // Offline for a moment: the next report tries again.
        }
        await loadMachines()
    }

    func loadMachines() async {
        guard let key = apiKey, let j = try? await Self.json(Self.request("switchboard/machines", key: key)),
              let list = j["machines"] as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        machines = list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let ip = m["tailscale_ip"] as? String ?? ""
            let port = (m["port"] as? NSNumber)?.intValue
            return Machine(id: id, name: m["name"] as? String ?? "Mac", online: m["online"] as? Bool ?? false,
                           lastSeen: (m["last_seen_at"] as? String).flatMap(iso.date(from:)),
                           address: ip.isEmpty ? "" : (port.map { "\(ip):\($0)" } ?? ip))
        }
    }

    private func refreshPerson() async {
        guard let key = apiKey else { return }
        switch await SBRemote.whoIs(key: key, server: Self.server) {
        case .person(let p): person = p
        case .rejected: problem = "Simplero no longer accepts this Mac's sign-in. Sign in again."
        case .unreachable: break
        }
    }

    /// This Mac on Tailscale: its first IPv4 address, its host name and its full name.
    nonisolated static func tailscaleSelf() -> (ip: String?, host: String?, dnsName: String?) {
        guard let r = SBBackground.run(SBRemote.tailscale, ["status", "--json", "--peers=false"], timeout: 8), r.code == 0,
              let j = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let me = j["Self"] as? [String: Any] else { return (nil, nil, nil) }
        let ips = me["TailscaleIPs"] as? [String] ?? []
        let dns = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        return (ips.first { $0.contains(".") } ?? ips.first, me["HostName"] as? String, dns)
    }

    // MARK: Helpers

    enum Failure: Error { case answer }

    private static func request(_ path: String, key: String) -> URLRequest {
        var req = URLRequest(url: URL(string: server + "/api/mobile/v1/" + path)!)
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Switchboard/\(SessionsVersion.shared.runningBuild)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        return req
    }

    private static func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.answer }
        return j
    }

    private static func form(_ fields: [String: String]) -> String {
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private enum Keychain {
        static let service = "com.simplero.switchboard.mac"

        static func query(_ server: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: server]
        }

        static func read(_ server: String) -> String? {
            var q = query(server)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func save(_ key: String, _ server: String) {
            delete(server)
            var q = query(server)
            q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }

        static func delete(_ server: String) { SecItemDelete(query(server) as CFDictionary) }
    }
}

extension SBAccount: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { PhoneLinkWindow.window ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow() }
    }
}

// MARK: The Phone Link window (Switchboard menu › Phone Link…)

enum PhoneLinkWindow {
    static var window: NSWindow?

    @MainActor static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Phone Link"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PhoneLinkView(account: SBAccount.shared))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await SBAccount.shared.loadMachines() }
    }

    /// Switchboard menu › Phone Link…, after About.
    @MainActor static func installMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              !appMenu.items.contains(where: { $0.title == "Phone Link…" }) else { return }
        let item = NSMenuItem(title: "Phone Link…", action: #selector(PhoneLinkMenuTarget.open(_:)), keyEquivalent: "")
        item.target = PhoneLinkMenuTarget.shared
        appMenu.insertItem(item, at: min(1, appMenu.items.count))
    }
}

final class PhoneLinkMenuTarget: NSObject {
    static let shared = PhoneLinkMenuTarget()
    @MainActor @objc func open(_ sender: Any?) { PhoneLinkWindow.show() }
}

struct PhoneLinkView: View {
    @ObservedObject var account: SBAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = account.person {
                Text("Signed in as \(p.name)").font(.headline)
                Text("Your iPhone finds this Mac by itself and connects over Tailscale.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Macs").font(.subheadline.weight(.semibold))
                    if account.machines.isEmpty {
                        Text("Reading the list…").foregroundStyle(.secondary)
                    }
                    ForEach(account.machines) { m in
                        HStack(spacing: 8) {
                            Text(m.name + (m.id == SBAccount.machineID ? " · this Mac" : "")).fontWeight(.medium)
                            Spacer()
                            // A word, not only a color.
                            Label(m.online ? "Online" : "Offline\(m.lastSeen.map { " · " + Self.ago($0) } ?? "")",
                                  systemImage: m.online ? "circle.fill" : "circle")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                                .foregroundStyle(m.online ? Color.green : Color.secondary)
                        }
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                HStack {
                    if let p = account.problem { Text(p).foregroundStyle(.orange).font(.callout) }
                    Spacer()
                    Button("Sign Out") { account.signOut() }
                }
            } else {
                Text("See this Mac's sessions on your iPhone").font(.headline)
                Text("Sign in with Simplero. Your iPhone then finds this Mac by itself and connects over Tailscale.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let p = account.problem { Text(p).foregroundStyle(.orange).font(.callout) }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(account.signingIn ? "Waiting for the browser…" : "Sign in with Simplero…") { account.signIn() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(account.signingIn)
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 300, alignment: .topLeading)
    }

    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}
