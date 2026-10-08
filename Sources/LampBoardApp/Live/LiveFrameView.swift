import AppKit
import LampBoardCore

/// The frame around a live session (D130): the theme's backdrop, a header with
/// the session's lamp, name and state, and a card holding the terminal.
///
/// The terminal sits on the card, and the card's colour is the terminal's own
/// background, so the bands Claude Code paints for itself match what is around
/// them. Everything that makes it look less like a terminal is out here, in
/// AppKit, where the theme can reach it without touching Claude's colours.
@MainActor
final class LiveFrameView: NSView {

    private var theme: LiveTheme
    private let lamp = LampDot()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Closing detaches · the session keeps running")
    private let card = CardView()
    let reattach = NSButton(title: "Open again", target: nil, action: nil)

    init(theme: LiveTheme, terminal: NSView) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        hint.font = .systemFont(ofSize: 11)
        for label in [title, detail, hint] { label.lineBreakMode = .byTruncatingTail; label.isSelectable = false }
        reattach.bezelStyle = .rounded
        reattach.controlSize = .small
        reattach.isHidden = true

        for view in [lamp, title, detail, hint, reattach, card] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            // Clear of the traffic lights of a window with a transparent title bar.
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),
            lamp.centerYAnchor.constraint(equalTo: topAnchor, constant: 20),
            lamp.widthAnchor.constraint(equalToConstant: 10),
            lamp.heightAnchor.constraint(equalToConstant: 10),
            title.leadingAnchor.constraint(equalTo: lamp.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: lamp.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.centerYAnchor.constraint(equalTo: lamp.centerYAnchor),
            reattach.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 10),
            reattach.centerYAnchor.constraint(equalTo: lamp.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: reattach.trailingAnchor, constant: 10),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            hint.centerYAnchor.constraint(equalTo: lamp.centerYAnchor),

            card.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        seat(terminal)
        apply(theme: theme)
    }

    /// The terminal on the card, at the card's margins.
    private func seat(_ terminal: NSView) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        if terminal.superview !== card { card.addSubview(terminal) }
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            terminal.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            terminal.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            terminal.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
    }

    /// A new terminal in the old one's seat, with the same margins.
    func replaceTerminal(_ old: NSView, with new: NSView) {
        old.removeFromSuperview()
        seat(new)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func apply(theme: LiveTheme) {
        self.theme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        title.textColor = NSColor(liveHex: theme.text)
        detail.textColor = NSColor(liveHex: theme.text).withAlphaComponent(0.62)
        hint.textColor = NSColor(liveHex: theme.text).withAlphaComponent(0.42)
        card.fill = NSColor(liveHex: theme.card)
        card.edge = (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.08)
        needsDisplay = true
    }

    func show(_ header: LiveHeading, ended: Bool) {
        title.stringValue = header.title
        detail.stringValue = ended ? "left · the session goes on in the background" : header.detail
        lamp.color = header.status.map(StatusPalette.nsColor(for:)) ?? NSColor(white: 0.5, alpha: 1)
        lamp.hollow = header.status == .idle || header.status == nil
        reattach.isHidden = !ended
        hint.isHidden = ended
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(liveHex: theme.backdropTop), ending: NSColor(liveHex: theme.backdropBottom))?
            .draw(in: bounds, angle: -70)
    }
}

/// The rounded card behind the terminal.
private final class CardView: NSView {
    var fill = NSColor.black { didSet { needsDisplay = true } }
    var edge = NSColor.clear { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        fill.setFill()
        path.fill()
        edge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The session's lamp, as the panel draws it: filled, or hollow at rest.
private final class LampDot: NSView {
    var color = NSColor.gray { didSet { needsDisplay = true } }
    var hollow = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if hollow {
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else {
            color.setFill()
            path.fill()
        }
    }
}
