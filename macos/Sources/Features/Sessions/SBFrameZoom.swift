import AppKit
import WebKit

/// The WebKit in macOS 27 does not zoom what is inside a frame. A page that zooms with CSS zoom on
/// its root (a Simplero Doc: its − 100% + control, ⌘+ and pinch) gets bigger, but the frames in it
/// only get bigger boxes: their text stays the same size. A Doc made of HTML pages is all frames,
/// so it does not zoom at all. Chrome zooms the frames too.
///
/// When this WebKit has the problem (a test page, drawn once off screen, says so), the page pane
/// gets a script in every frame: a page tells each frame in it how much it is zoomed, and the
/// frame zooms its own page by that much. Where WebKit zooms frames itself, nothing is added.
@MainActor
enum SBFrameZoom {
    /// nil until the test page answered.
    private(set) static var needed: Bool?
    private static let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private static var probe: Probe?

    /// The page pane's pages call this for their web view's configuration.
    static func prepare(_ controller: WKUserContentController) {
        if needed == true { add(to: controller) }
        else if needed == nil { controllers.add(controller); check() }
    }

    private static func add(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// The answer is kept for this macOS build: the next start needs no test.
    private static var key: String { "sessions.frameZoom." + ProcessInfo.processInfo.operatingSystemVersionString }

    static func check() {
        if needed != nil || probe != nil { return }
        if let known = UserDefaults.standard.object(forKey: key) as? Bool { finish(known); return }
        probe = Probe { result in
            MainActor.assumeIsolated {
                probe = nil
                // No answer (no picture): no fix, and no answer kept; the next start tests again.
                if let result { UserDefaults.standard.set(result, forKey: key) }
                finish(result ?? false)
            }
        }
    }

    private static func finish(_ result: Bool) {
        needed = result
        if result { for c in controllers.allObjects { add(to: c) } }
        controllers.removeAllObjects()
    }

    /// A page zoomed 4 times with a black square 20 px tall in it, and the same square in a frame.
    /// In the picture both are 80 px tall when WebKit zooms the frame; the frame's is 20 px when not.
    private final class Probe: NSObject, WKNavigationDelegate {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let done: (Bool?) -> Void
        var answered = false

        init(_ done: @escaping (Bool?) -> Void) {
            self.done = done
            super.init()
            window.isReleasedWhenClosed = false
            window.contentView = web   // never shown: it only gives the page a size to draw at
            web.navigationDelegate = self
            let square = "<div style='width:20px;height:20px;background:#000'></div>"
            let html = "<html style='zoom:4'><body style='margin:0;background:#fff'>" + square
                + "<iframe style='display:block;border:0;width:40px;height:40px;margin-left:30px' srcdoc=\"<body style='margin:0;background:#fff'>"
                + square + "</body>\"></iframe></body></html>"
            web.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.answer(nil) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.web.takeSnapshot(with: nil) { image, _ in
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { self.answer(nil); return }
                    // Dark rows in a column through the page's square, and one through the frame's.
                    let scale = Double(rep.pixelsWide) / 300
                    func dark(_ x: Double) -> Int {
                        var n = 0
                        for y in 0..<rep.pixelsHigh {
                            if let c = rep.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.deviceRGB), c.brightnessComponent < 0.3 { n += 1 }
                        }
                        return n
                    }
                    let page = dark(40), frame = dark(130)   // the frame starts at 30 × 4 = 120
                    guard page > 0 else { self.answer(nil); return }
                    self.answer(Double(frame) < Double(page) * 0.6)
                }
            }
        }

        func answer(_ result: Bool?) {
            guard !answered else { return }
            answered = true
            web.navigationDelegate = nil
            window.contentView = nil
            done(result)
        }
    }

    /// In every frame of a pane page. A page tells each frame in it how much it is zoomed
    /// ({ switchboardFrameZoom }), when its root's zoom changes and when a frame loads. A frame
    /// that is told a zoom (other than 1) zooms its own page by it, on top of the page's own zoom.
    static let script = #"""
    (function () {
      if (window.__switchboardFrameZoom) return
      window.__switchboardFrameZoom = true
      var root = document.documentElement
      var given = 1
      var own = null
      var zoomOf = function () { return parseFloat(getComputedStyle(root).zoom) || 1 }
      var tell = function (frame, z) {
        try { if (frame.contentWindow) frame.contentWindow.postMessage({ switchboardFrameZoom: z }, '*') } catch (e) {}
      }
      // How much this page is zoomed, for the frames in it. A frame zoomed by Switchboard passes
      // nothing on: frames in frames stay as WebKit draws them.
      var sent = 1
      var tellAll = function (force) {
        if (given !== 1) return
        var z = zoomOf()
        if (z === sent && !force) return
        sent = z
        var frames = document.querySelectorAll('iframe')
        for (var i = 0; i < frames.length; i++) tell(frames[i], z)
      }
      new MutationObserver(function () { tellAll(false) }).observe(root, { attributes: true, attributeFilter: ['style', 'class'] })
      document.addEventListener('load', function (event) {
        var t = event.target
        if (t && t.tagName === 'IFRAME' && given === 1 && zoomOf() !== 1) tell(t, zoomOf())
      }, true)
      addEventListener('message', function (event) {
        var z = event.data && event.data.switchboardFrameZoom
        if (event.source !== parent || parent === window || typeof z !== 'number' || !(z > 0) || z === given) return
        if (own === null) own = { zoom: zoomOf(), inline: root.style.zoom }
        given = z
        root.style.zoom = z === 1 ? own.inline : String(z * own.zoom)
      })
    })()
    """#
}
