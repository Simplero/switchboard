import AppKit
import Combine
import SwiftUI
import WebKit

/// Switchboard's own pages in the pane on the right (instead of a Doc while one is open):
///
/// - The Board (⌘B): every session is a card in a column you name and order yourself (Now,
///   Waiting, Later…), so a session that waits for a deploy is parked, not forgotten.
/// - In this session (⌘I): what the session in front works on: its topics, what is done and
///   open in each, the link to check, what was put off for later.
///
/// Each is one page (Pages/switchboard-board.html, switchboard-session.html) that moves into
/// the window in front, like the sidebar. The same key again closes it.
@MainActor
final class SBToolPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    enum Kind: String { case board, session }
    let kind: Kind
    let webView: WKWebView
    private var loaded = false

    init(_ kind: Kind) {
        self.kind = kind
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        webView = web
        super.init()
        config.userContentController.add(WeakHandler(self), name: "sessions")
        web.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "switchboard-\(kind.rawValue)", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    var title: String { kind == .board ? "Board" : "In this session" }

    /// The sessions, the board and the session in front, for the page.
    func push() {
        guard loaded, let json = Switchboard.shared.currentJSON() else { return }
        var extra: [String: Any] = ["board": SBBoard.shared.json, "front": SessionsStore.shared.focusedSurfaceID ?? ""]
        extra["now"] = Int(Date().timeIntervalSince1970)
        guard let e = try? JSONSerialization.data(withJSONObject: extra) else { return }
        webView.evaluateJavaScript("window.SB && SB.setData(\(json), \(String(decoding: e, as: UTF8.self)))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let store = SessionsStore.shared
        switch type {
        case "ready":
            loaded = true
            push()
        case "open":
            // Go to that session (the pane stays open in its window).
            if let k = body["k"] as? String { store.open(key: k, via: "the \(title.lowercased())") }
        case "board":
            if let state = body["board"] as? [String: Any] {
                SBBoard.shared.save(state)
                SessionsDocPanes.shared.pushTools(except: self)
            }
        case "op":
            guard let o = body["o"] as? [String: Any], let op = o["op"] as? String, ["send", "new", "done", "close", "pin_off", "ack"].contains(op) else { return }
            if let k = o["k"] as? String, let action = ["done": "Archive", "close": "Close", "pin_off": "Turn off"][op], !store.confirmClose(k, action: action) { return }
            SessionSwitchLog.because("the \(title.lowercased()): \(op)")
            store.send(o)
        case "link":
            // A Doc opens in the pane, so the tool page makes room for it.
            guard let s = body["url"] as? String, let url = URL(string: s) else { return }
            if SessionsDocPanes.isDoc(url) || SessionsDocPanes.staysInPane(url) { SessionsDocPanes.shared.tool = nil }
            SessionsLinkOpener.open(url)
        case "close":
            SessionsDocPanes.shared.tool = nil
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The page itself loads from the app; any link goes through "link" above.
        if action.navigationType == .linkActivated, let url = action.request.url {
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" { SessionsLinkOpener.open(url) }
            return
        }
        decisionHandler(.allow)
    }

    /// WKUserContentController keeps its handler: a weak one, so nothing stays alive by it.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: SBToolPage?
        init(_ t: SBToolPage) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(c, didReceive: m) }
        }
    }
}

/// The Board's columns and cards (board.json in Switchboard's data folder). The page edits it
/// and sends the whole of it back; Switchboard keeps it and gives it to every page.
@MainActor
final class SBBoard {
    static let shared = SBBoard()
    static var path: String { SBPaths.data + "/board.json" }
    private(set) var json: [String: Any]

    static let start: [String: Any] = [
        "cols": [
            ["id": "now", "name": "Now", "color": "blue"],
            ["id": "waiting", "name": "Waiting", "color": "yellow"],
            ["id": "later", "name": "Later", "color": "purple"],
        ],
        "cards": [String: Any](),
        "collapsed": [String](),
    ]

    private init() {
        if let d = FileManager.default.contents(atPath: Self.path),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["cols"] is [Any] {
            json = j
        } else {
            json = Self.start
        }
    }

    /// Only what a board has: columns (id, name, color), cards by session key, folded columns.
    func save(_ state: [String: Any]) {
        guard let cols = state["cols"] as? [[String: Any]], !cols.isEmpty else { return }
        let clean: [[String: Any]] = cols.prefix(12).compactMap { c in
            guard let id = c["id"] as? String, !id.isEmpty else { return nil }
            return ["id": String(id.prefix(40)), "name": String((c["name"] as? String ?? "Column").prefix(40)),
                    "color": String((c["color"] as? String ?? "blue").prefix(20))]
        }
        let ids = Set(clean.compactMap { $0["id"] as? String })
        var cards: [String: Any] = [:]
        for (k, v) in (state["cards"] as? [String: Any]) ?? [:] {
            guard var c = v as? [String: Any], let col = c["col"] as? String, ids.contains(col) else { continue }
            c["note"] = String((c["note"] as? String ?? "").prefix(2000))
            c["linear"] = String((c["linear"] as? String ?? "").prefix(300))
            c["waits"] = ((c["waits"] as? [String]) ?? []).prefix(8).map { String($0.prefix(120)) }
            c["pos"] = (c["pos"] as? NSNumber)?.doubleValue ?? 0
            cards[String(k.prefix(120))] = c
        }
        json = ["cols": clean, "cards": cards, "collapsed": ((state["collapsed"] as? [String]) ?? []).filter { ids.contains($0) }]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            SBFiles.queue.async { _ = SBFiles.writeAtomic(d, Self.path) }
        }
    }
}

extension SessionsDocPanes {
    /// The tool pages, made when first opened.
    private static var made: [SBToolPage.Kind: SBToolPage] = [:]
    private static var watch: AnyCancellable?

    func toolPage(_ kind: SBToolPage.Kind) -> SBToolPage {
        if let p = Self.made[kind] { return p }
        let p = SBToolPage(kind)
        Self.made[kind] = p
        // The session in front changed: In this session shows that one.
        if Self.watch == nil {
            Self.watch = SessionsStore.shared.$focusedSurfaceID.removeDuplicates().sink { _ in
                DispatchQueue.main.async { SessionsDocPanes.shared.pushTools() }
            }
        }
        return p
    }

    /// ⌘B / ⌘I: open that page in the pane, or close it when it is open.
    func toggle(_ kind: SBToolPage.Kind) {
        tool = tool == kind.rawValue ? nil : kind.rawValue
        if tool != nil { toolPage(kind).push() }
    }

    /// The sessions changed: the open tool pages get them.
    func pushTools(except: SBToolPage? = nil) {
        for p in Self.made.values where p !== except && tool == p.kind.rawValue { p.push() }
    }
}

/// The pane with a tool page: its name and a close button, then the page.
struct ToolPaneView: View {
    let page: SBToolPage
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(page.title).font(.system(size: 13, weight: .semibold))
                Text(page.kind == .board ? "⌘B" : "⌘I").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        Text("Close").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 9).frame(minHeight: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (\(page.kind == .board ? "⌘B" : "⌘I"))")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            Divider()
            ToolWebHolderView(web: page.webView)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Holds a tool page's web view in one window; it moves into the window in front.
struct ToolWebHolderView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> ToolWebHolder { ToolWebHolder(web: web) }
    func updateNSView(_ v: ToolWebHolder, context: Context) { v.web = web; v.adoptIfFront() }
}

final class ToolWebHolder: NSView {
    var web: WKWebView
    private var observer: Any?

    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.adopt() }
        }
        adoptIfFront()
    }

    @MainActor func adoptIfFront() {
        guard let window else { return }
        if window.isKeyWindow || web.superview == nil { adopt() }
    }

    @MainActor func adopt() {
        guard web.superview !== self else { return }
        web.removeFromSuperview()
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        addSubview(web)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
