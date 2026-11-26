import AppKit
import SwiftUI
import WebKit

/// A page next to a session: a Simplero Doc you click in the panel (or ⌘-click in the terminal)
/// opens on the right of the terminal, beside the work it belongs to, instead of in another
/// browser tab. One page per session; it stays while you switch sessions and comes back with
/// the session. "Open in browser" sends it to your browser as before.
@MainActor
final class SessionsDocPanes: ObservableObject {
    static let shared = SessionsDocPanes()

    /// Session id (TerminalController.sessionsWorkspace) → its page.
    @Published private(set) var pages: [String: DocPage] = [:]
    /// A page of Switchboard's own in the pane, over the Doc (SBTools): "board" or "session".
    @Published var tool: String?

    /// Simplero Docs: the share host, and Docs in the admin.
    nonisolated static func isDoc(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "doc.simplero.me" || host == "doc.simplero.me.test" { return true }   // .test: the development server
        return (host == "simplero.com" || host.hasSuffix(".simplero.com")) && url.path.hasPrefix("/admin/docs")
    }

    /// Pages that stay in the pane when you click on (Simplero itself); others open in your browser.
    nonisolated static func staysInPane(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return isDoc(url) || host == "simplero.com" || host.hasSuffix(".simplero.com") || host.hasSuffix(".simplero.me")
            || host == "simplero.test" || host.hasSuffix(".simplero.test")
    }

    func open(_ url: URL, session ws: String) {
        // In this session (⌘I) is over the Doc: close it, so the Doc you clicked is in front.
        if tool == SBToolPage.Kind.session.rawValue { tool = nil }
        let page = pages[ws] ?? DocPage()
        pages[ws] = page
        page.load(url)
    }

    func close(session ws: String) {
        pages[ws]?.webView.stopLoading()
        pages[ws] = nil
    }

    /// The session of the window in front, if it is a session window.
    static var frontSession: String? {
        (NSApp.keyWindow?.windowController as? TerminalController)?.sessionsWorkspace
    }

    /// Simplero's login page (the pane is not signed in, or its sign-in ran out).
    nonisolated static func isLoginPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host == "secure.simplero.com" || host == "secure.simplero.test") && url.path == "/login"
    }

    /// A one-time sign-in link to `url`, made with the Mac's Simplero sign-in (Phone Link), the
    /// same as the phone's in-app pages. Nil without a sign-in.
    static func signInURL(for url: URL) async -> URL? {
        guard let key = SBAccount.shared.mobileKey else { return nil }
        var req = URLRequest(url: URL(string: SBAccount.server + "/api/mobile/v1/users/generate_auto_login_url")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["return_to": url.absoluteString])
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = j["url"] as? String, let signed = URL(string: s), signed != url else { return nil }
        return signed
    }
}

/// One page in the pane, with its own history.
@MainActor
final class DocPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    /// The page is Simplero's login and the Mac is not signed in to Phone Link (so the pane
    /// cannot sign itself in): the bar offers Phone Link.
    @Published var needsPhoneLink = false
    private var observers: [NSKeyValueObservation] = []
    private var lastSignIn: Date = .distantPast

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // stays signed in between runs
        SBFrameZoom.prepare(config.userContentController)   // a zoomed Doc zooms its HTML pages too
        let web = DocWebView(frame: .zero, configuration: config)
        webView = web
        super.init()
        web.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            webView.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.loading = w.isLoading } },
        ]
    }

    /// Counts loads, so a sign-in answer that comes back after you opened another page is dropped.
    private var generation = 0
    /// The page that waits for a sign-in (shown again when Phone Link signs in).
    private(set) var waitingFor: URL?

    func load(_ url: URL) {
        generation += 1
        webView.load(URLRequest(url: url))
    }

    /// Phone Link just signed in: the page that waited on the login page comes now.
    func signedInNow() {
        guard needsPhoneLink, let wanted = waitingFor else { return }
        needsPhoneLink = false
        lastSignIn = .distantPast
        load(wanted)
    }

    // MARK: Find on the page (⌘F)

    /// The find bar shows under the buttons.
    @Published var finding = false
    @Published var findText = ""
    /// "4 found", "Not found", or nothing while the field is empty.
    @Published var findResult = ""
    private var lastFind = ""
    /// The find fields (one in each of the session's tab windows; the page moves into the one in front).
    let findFields = NSHashTable<NSTextField>.weakObjects()
    /// The find field in the window the page is in.
    var findField: NSTextField? { findFields.allObjects.first { $0.window != nil && $0.window === webView.window } }

    /// ⌘F: the find bar opens and its field takes the keyboard, with its text selected, so you type
    /// at once (the new text replaces the old).
    func openFind() {
        finding = true
        focusFindField()
        if !findText.isEmpty { find() }
    }

    /// The field takes the keyboard by AppKit, not by SwiftUI focus (that one did not always
    /// take it from the page). The bar's field may come a moment later: try again for half a second.
    private func focusFindField(tries: Int = 15) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.finding else { return }
            guard let f = self.findField, let w = f.window else {
                if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.focusFindField(tries: tries - 1) } }
                return
            }
            if !self.hasFindField(w.firstResponder) { w.makeFirstResponder(f) }
            f.currentEditor()?.selectAll(nil)
        }
    }

    /// The responder is one of the find fields (its field editor).
    func hasFindField(_ r: NSResponder?) -> Bool {
        guard let r else { return false }
        let field = (r as? NSTextView)?.delegate as AnyObject? ?? r
        return findFields.allObjects.contains { $0 === field }
    }

    func closeFind() {
        finding = false
        findResult = ""
        webView.window?.makeFirstResponder(webView)
    }

    /// The next (or previous) place the text is on the page: WebKit selects it and scrolls to it.
    func find(backwards: Bool = false) {
        let q = findText
        guard !q.isEmpty else { findResult = ""; return }
        if q != lastFind { findResult = "" }   // no count of the text before while this one is found
        lastFind = q
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.caseSensitive = false
        c.wraps = true
        webView.find(q, configuration: c) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, q == self.findText else { return }
                if r.matchFound { self.countMatches(q) } else { self.findResult = "Not found" }
            }
        }
    }

    /// How many times the text is on the page (the page's visible text, any case).
    private func countMatches(_ q: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [q]), let arg = String(data: data, encoding: .utf8) else { return }
        let js = "(function(q){q=q.toLowerCase();var t=(document.body?document.body.innerText:'').toLowerCase(),n=0,i=0;"
            + "while((i=t.indexOf(q,i))!==-1){n++;i+=q.length;}return n;})(\(arg)[0])"
        webView.evaluateJavaScript(js) { [weak self] v, _ in
            MainActor.assumeIsolated {
                guard let self, q == self.findText else { return }
                let n = (v as? NSNumber)?.intValue ?? 0
                self.findResult = n == 1 ? "1 found" : n > 1 ? "\(n) found" : "Found"
            }
        }
    }

    /// Simplero pages stay here; a link to anywhere else opens in your browser. Simplero's login
    /// page signs in by itself with the Mac's Phone Link sign-in, then shows the page you wanted.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame != false, let url = action.request.url, SessionsDocPanes.isLoginPage(url) {
            let wanted = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "return_to" }?.value.flatMap(URL.init(string:))
            needsPhoneLink = !SBAccount.shared.signedIn
            waitingFor = wanted
            // Once a minute at most, so a sign-in Simplero refuses cannot loop.
            if let wanted, SBAccount.shared.signedIn, Date().timeIntervalSince(lastSignIn) > 60 {
                lastSignIn = Date()
                decisionHandler(.cancel)
                let gen = generation
                Task {
                    let signed = await SessionsDocPanes.signInURL(for: wanted)
                    guard gen == self.generation else { return }   // you opened another page meanwhile
                    self.load(signed ?? url)
                }
                return
            }
        } else if action.targetFrame?.isMainFrame != false {
            needsPhoneLink = false
        }
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? ""), !SessionsDocPanes.staysInPane(url) {
            SessionsLinkOpener.open(url, nextToSession: false)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// A link that wants a new window: a Simplero page here, anything else in your browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if SessionsDocPanes.staysInPane(url) { webView.load(URLRequest(url: url)) } else { SessionsLinkOpener.open(url, nextToSession: false) }
        }
        return nil
    }
}

/// The pane: a bar (back, forward, reload, title, find, open in browser, close) over the page,
/// and the find bar under it while you search the page (⌘F).
struct DocPaneView: View {
    @ObservedObject var page: DocPage
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                bar("chevron.left", "Back") { page.webView.goBack() }.disabled(!page.canGoBack)
                bar("chevron.right", "Forward") { page.webView.goForward() }.disabled(!page.canGoForward)
                bar(page.loading ? "xmark" : "arrow.clockwise", page.loading ? "Stop loading" : "Reload") {
                    if page.loading { page.webView.stopLoading() } else { page.webView.reload() }
                }
                Text(page.title.isEmpty ? (page.webView.url?.host ?? "") : page.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .help(page.webView.url?.absoluteString ?? "")
                bar("magnifyingglass", "Find on this page (⌘F)") { page.openFind() }
                bar("arrow.up.right.square", "Open this page in your browser", word: "Browser") {
                    if let u = page.webView.url { SessionsLinkOpener.open(u, nextToSession: false) }
                }
                bar("xmark", "Close this page", word: "Close", action: close)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            Divider()
            if page.finding {
                findBar
                Divider()
            }
            if page.needsPhoneLink {
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.system(size: 11))
                    Text("Sign in once with Phone Link, and pages here sign in by themselves.")
                        .font(.system(size: 12)).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Phone Link…") { PhoneLinkWindow.show() }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }
            DocWebHolderView(page: page)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Find on the page: ↩ next, ⇧↩ previous, esc closes it.
    private var findBar: some View {
        HStack(spacing: 6) {
            FindField(page: page, text: page.findText)
                .onChange(of: page.findText) { _ in page.find() }
            Text(page.findResult)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            bar("chevron.up", "Previous (⇧↩)") { page.find(backwards: true) }.disabled(page.findText.isEmpty)
            bar("chevron.down", "Next (↩)") { page.find() }.disabled(page.findText.isEmpty)
            bar(nil, "Stop finding (esc)", word: "Done") { page.closeFind() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// A button of the bar: a big symbol (and a word for the ones a symbol does not make clear)
    /// on a soft background, so it reads as a button.
    private func bar(_ symbol: String?, _ help: String, word: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                if let word { Text(word).font(.system(size: 13, weight: .semibold)) }
            }
            .padding(.horizontal, word == nil ? 0 : 9)
            .frame(minWidth: 34, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaneButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The find bar's field (AppKit, so ⌘F can give it the keyboard for sure): ↩ next, ⇧↩ previous,
/// esc closes the bar.
private struct FindField: NSViewRepresentable {
    let page: DocPage
    /// The text, so SwiftUI updates the field when the text changes from outside it.
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: page.findText)
        f.placeholderString = "Find on this page"
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: 13)
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.delegate = context.coordinator
        page.findFields.add(f)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.page = page
        page.findFields.add(f)
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var page: DocPage
        init(page: DocPage) { self.page = page }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            MainActor.assumeIsolated { page.findText = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch selector {
                case #selector(NSResponder.insertNewline(_:)):
                    page.find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    page.closeFind()
                    return true
                default: return false
                }
            }
        }
    }
}

/// The pane's buttons: a soft rounded background that gets darker on hover and on a press.
private struct PaneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PaneButton(configuration: configuration) }

    private struct PaneButton: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hover ? 0.12 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.14)))
                .opacity(enabled ? 1 : 0.35)
                .onHover { hover = $0 }
        }
    }
}

/// The pane's web view. ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z go straight to the page when it has the keyboard
/// (through the menu they did not arrive, as in the sidebar).
final class DocWebView: WKWebView {
    weak var owner: DocPage?

    /// A click in the page gives it the keyboard.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    /// A pinch zooms a page that zooms itself (a Simplero Doc). In an app WebKit gives the page
    /// neither Safari's gesture events nor a magnification, so the pinch comes as Chrome sends
    /// it: wheel events with Ctrl, under the pointer. A page without its own zoom ignores them.
    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let x = Double(p.x), y = Double(isFlipped ? p.y : bounds.height - p.y)
        let delta = -Foundation.log(max(0.05, 1 + Double(event.magnification))) * 100
        let js = "const e = new WheelEvent('wheel', {deltaY: d, deltaMode: 0, ctrlKey: true, clientX: x, clientY: y, bubbles: true, cancelable: true, composed: true});"
            + " (document.elementFromPoint(x, y) || document.documentElement).dispatchEvent(e); return e.defaultPrevented"
        callAsyncJavaScript(js, arguments: ["d": delta, "x": x, "y": y], in: nil, in: .page) { _ in }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let r = window?.firstResponder as? NSView
        guard event.type == .keyDown, let r, r === self || r.isDescendant(of: self) else { return super.performKeyEquivalent(with: event) }
        // ⌘F finds on the page; ⌘G and ⇧⌘G go to the next and previous place.
        let findMods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (findMods, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "f"): owner?.openFind(); return true
        case (.command, "g"): if owner?.findText.isEmpty == false { owner?.find(); return true }
        case ([.command, .shift], "g"): if owner?.findText.isEmpty == false { owner?.find(backwards: true); return true }
        default: break
        }
        // ⌘ arrows (⇧ to select) move in the page's text or scroll it.
        if event.modifierFlags.contains(.command), (123...126).contains(event.keyCode) {
            keyDown(with: event)
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let action: Selector?
        switch (mods, key) {
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        return NSApp.sendAction(action, to: self, from: nil)
    }
}

extension NSView {
    /// The pane's web view this view sits in, if any (WebKit can make an inner view first responder).
    var enclosingDocWebView: DocWebView? {
        var v: NSView? = superview
        while let x = v { if let d = x as? DocWebView { return d }; v = x.superview }
        return nil
    }
}

/// Holds the page's web view in one window. A session's tabs are separate windows, so the web
/// view moves into the one in front (like the sidebar).
struct DocWebHolderView: NSViewRepresentable {
    let page: DocPage
    func makeNSView(context: Context) -> DocWebHolder { DocWebHolder(page: page) }
    func updateNSView(_ nsView: DocWebHolder, context: Context) { nsView.page = page; nsView.adoptIfFront() }
}

final class DocWebHolder: NSView {
    var page: DocPage
    private var observer: Any?

    init(page: DocPage) {
        self.page = page
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
        if window.isKeyWindow || page.webView.superview == nil { adopt() }
    }

    @MainActor func adopt() {
        let web = page.webView
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
