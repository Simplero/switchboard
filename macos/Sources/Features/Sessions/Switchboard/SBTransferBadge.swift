import AppKit

/// A small box on a terminal while files go to the session's machine: what goes where, and
/// how far it is. It shows the moment you drop or paste, before the connection is up.
@MainActor
final class SBTransferBadge: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let what: String, machine: String, total: Int64

    private init(what: String, machine: String, total: Int64) {
        self.what = what; self.machine = machine; self.total = total
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(bar)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            widthAnchor.constraint(equalToConstant: 320),
        ])
        bar.startAnimation(nil)
        label.stringValue = "Connecting to \(machine) to copy \(what)…"
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(label.stringValue)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// On the terminal's bottom right. Nil when the terminal is gone.
    static func show(on view: NSView?, what: String, machine: String, total: Int64) -> SBTransferBadge? {
        guard let view else { return nil }
        let b = SBTransferBadge(what: what, machine: machine, total: total)
        view.addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            b.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
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
        if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
        bar.doubleValue = part
        label.stringValue = "Copying \(what) to \(machine): \(Int(part * 100))% · "
            + "\(Self.bytes.string(fromByteCount: sent)) of \(Self.bytes.string(fromByteCount: total))"
        setAccessibilityLabel(label.stringValue)
    }

    /// Done (or failed): the box goes.
    func finish() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { self.removeFromSuperview() } })
    }
}
