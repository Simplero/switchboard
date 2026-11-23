import AppKit

/// A small box on a terminal while files go to the session's machine: what goes where, and
/// how far it is. It shows the moment you drop or paste, before the connection is up.
@MainActor
final class SBTransferBadge: NSVisualEffectView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let bar = Bar()
    private let machine: String, total: Int64

    private init(what: String, machine: String, total: Int64) {
        self.machine = machine; self.total = total
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.stringValue = "Copying \(what) to \(machine)"
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.stringValue = "Connecting to \(machine)…"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        for v in [title, detail, spinner, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            spinner.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            bar.heightAnchor.constraint(equalToConstant: 5),
            detail.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 5),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(equalToConstant: 340).withPriority(.defaultHigh),
        ])
        spinner.startAnimation(nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(title.stringValue + ". " + detail.stringValue)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// On the terminal's bottom right; never wider than the terminal. Nil when the terminal is gone.
    static func show(on view: NSView?, what: String, machine: String, total: Int64) -> SBTransferBadge? {
        guard let view else { return nil }
        let b = SBTransferBadge(what: what, machine: machine, total: total)
        view.addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            b.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            b.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 14),
        ])
        return b
    }

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    func update(sent: Int64) {
        guard total > 0 else { return }
        let part = min(1, Double(sent) / Double(total))
        bar.part = part
        detail.stringValue = "\(Int(part * 100))% · \(Self.bytes.string(fromByteCount: sent)) of \(Self.bytes.string(fromByteCount: total))"
        setAccessibilityLabel(title.stringValue + ". " + detail.stringValue)
    }

    /// Done (or failed): the box goes.
    func finish() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { self.removeFromSuperview() } })
    }

    /// How much has gone: the filled part of a thin bar. The words below say the same in %.
    private final class Bar: NSView {
        var part: Double = 0 { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.height / 2
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
            guard part > 0 else { return }
            var fill = bounds
            fill.size.width = max(bounds.height, bounds.width * part)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}
