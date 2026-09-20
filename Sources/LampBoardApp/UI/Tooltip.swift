import AppKit
import LampBoardCore
import SwiftUI

/// The panel's own tooltips, because AppKit's never appear here.
///
/// WHY THIS EXISTS
/// `.help(…)` compiles, reads well, and shows nothing in this app. A tooltip is
/// put on screen by `NSToolTipManager`, which wants the window under the pointer
/// to be key and the application to be active — and this panel is neither by
/// design: it is a `nonactivatingPanel` that becomes key only in the instant of a
/// click, so that clicking a light does not take the focus away from the editor
/// (D5). Every `.help` on a row was therefore dead text, and the row's whole
/// second layer — the exact context figure, the model, the folder under a renamed
/// row, the slot — was written and never displayed.
///
/// So the panel carries its own. One borderless window, reused, that ignores the
/// mouse entirely and never becomes key: it cannot be hovered, cannot be clicked,
/// and cannot take the focus from anything.
@MainActor
enum Tooltip {

    /// How long the pointer has to rest before the text appears.
    ///
    /// Long enough that crossing the column on the way somewhere else stays
    /// silent, short enough that stopping on a row feels answered. AppKit's own
    /// delay is user-configurable and unreadable from here; this is the value the
    /// prototype was played with.
    private static let delay: TimeInterval = 0.45

    private static var panel: NSPanel?
    private static var pending: DispatchWorkItem?
    private static var dismissals: Any?

    /// What a tooltip can be: a sentence, or a row's whole second layer.
    enum Content {
        /// One line, for a control that does one thing.
        case text(String)
        /// A row: fields, the context bar, what each session of a group is doing.
        case card(RowSummary)
        /// One account's allowance: every limit, its bar, and when it comes back.
        /// Its own case rather than a `RowSummary` with the session parts left
        /// blank — an allowance has no state and no last message, and filling those
        /// in to reuse the view would put a status word on a thing with no status.
        case allowance(AllowanceReport)
    }

    /// Shows something under the pointer once it has rested there.
    ///
    /// Calling it again while one is up replaces it without waiting: moving
    /// between two rows should read as one tooltip following the pointer, not as
    /// a flicker and a new delay.
    static func show(_ content: Content) {
        pending?.cancel()

        if panel?.isVisible == true {
            present(content)
            return
        }

        let work = DispatchWorkItem { present(content) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func show(_ text: String) { show(.text(text)) }
    static func show(_ summary: RowSummary) { show(.card(summary)) }
    static func show(_ report: AllowanceReport) { show(.allowance(report)) }

    static func hide() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }

    // MARK: - Internals

    private static func present(_ content: Content) {
        let panel = panel ?? makePanel()
        Self.panel = panel

        let hosting = view(for: content)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        // `orderFrontRegardless` and never `makeKey`: the point of the panel this
        // belongs to is that nothing here ever takes the focus.
        panel.orderFrontRegardless()

        startWatchingForDismissal()
    }

    /// The hosted view, already carrying a width.
    ///
    /// THE ORDER MATTERS AND IT BIT ONCE
    /// A borderless window has no layout to size it: the size has to be known
    /// before it is shown. The first version asked `NSHostingView.fittingSize`
    /// for a view that had no width to wrap against, so SwiftUI laid the text out
    /// one word per line and answered **358 by 3,332 points** — measured, from the
    /// window list, two thousand points above the top of the screen.
    ///
    /// The fix is not a cleverer measurement, it is deciding the width first. Both
    /// contents below declare their own `.frame(width:)`, so by the time
    /// `fittingSize` is asked there is only one unknown left, and it is the height.
    private static func view(for content: Content) -> NSHostingView<AnyView> {
        switch content {
        case .text(let text):
            // A sentence gets only as much width as it needs, up to the cap: a
            // six-word tooltip stretched to the width of a card would read as an
            // empty box with a line in it.
            let font = NSFont.systemFont(ofSize: 11)
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return NSHostingView(rootView: AnyView(
                chrome(TooltipText(text: text, width: min(textWidth, ceil(bounds.width) + 1)))
            ))
        case .card(let summary):
            return NSHostingView(rootView: AnyView(
                chrome(TooltipCard(summary: summary, width: cardWidth))
            ))
        case .allowance(let report):
            return NSHostingView(rootView: AnyView(
                chrome(AllowanceCard(report: report, width: cardWidth, now: Date()))
            ))
        }
    }

    /// The surface both contents sit on.
    private static func chrome(_ content: some View) -> some View {
        content
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(TooltipBackground())
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }

    /// A sentence wraps at most here; a card is always exactly this wide.
    private static let textWidth: CGFloat = 300
    /// Wide enough for `860,960 of 1,000,000` beside its label without wrapping,
    /// narrow enough that a card never reads as a window.
    private static let cardWidth: CGFloat = 296

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // The card is the panel's second layer and is drawn in the same light.
        panel.appearance = StatusPalette.appearance
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the panel it explains, below the system menus. A tooltip that a
        // context menu opens behind would be a tooltip covering the menu.
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        return panel
    }

    /// Below and to the right of the pointer, kept inside the screen it is on.
    ///
    /// Cocoa's origin is bottom-left, so "below the pointer" is a *smaller* y —
    /// the sign that is wrong in every first version of this function.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = mouse.x + 14
        var y = mouse.y - size.height - 12

        if x + size.width > bounds.maxX { x = max(bounds.minX, mouse.x - size.width - 14) }
        // No room underneath — the pointer is near the bottom of the screen —
        // so it goes above instead of being clamped into a strip it does not fit.
        if y < bounds.minY { y = min(bounds.maxY - size.height, mouse.y + 18) }
        return NSPoint(x: x, y: y)
    }

    /// A click or a scroll takes it away.
    ///
    /// Hovering is not the only way a tooltip becomes wrong: a right-click opens
    /// the row's menu over the very row being explained, and `.contextMenu` gives
    /// no notice that it did. A local monitor sees every event this app gets,
    /// which is exactly the set of events that can make the text stale.
    private static func startWatchingForDismissal() {
        guard dismissals == nil else { return }
        dismissals = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { hide() }
            return event
        }
    }
}

/// One sentence, wrapped at a width decided before it is drawn.
private struct TooltipText: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
    }
}

private struct TooltipBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .toolTip
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// The panel's tooltip. Replaces `.help(…)`, which shows nothing in a window
    /// that is never key — see `Tooltip`.
    func tooltip(_ text: String) -> some View {
        tooltip(.text(text))
    }

    /// A row's whole second layer, as a card.
    func tooltip(_ summary: RowSummary) -> some View {
        tooltip(.card(summary))
    }

    /// One account's allowance, as a card in the same grammar.
    func tooltip(_ report: AllowanceReport) -> some View {
        tooltip(.allowance(report))
    }

    private func tooltip(_ content: Tooltip.Content) -> some View {
        onHover { inside in
            if inside { Tooltip.show(content) } else { Tooltip.hide() }
        }
    }
}
