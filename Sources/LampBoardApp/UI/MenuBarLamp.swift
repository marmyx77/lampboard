import AppKit
import LampBoardCore
import SwiftUI

/// One lamp in the menu bar, standing for the whole column.
///
/// WHY ONE LAMP AND NOT SIX
/// The menu bar is about twenty-two points tall and shared with every other
/// application on the machine. Six lamps up there would be a second column,
/// worse than the first at everything the first is for, and it would cost the
/// menu bar's own budget: the row of icons beside the clock is the scarcest
/// space on a Mac. So the icon says the one thing a glance can carry — *the most
/// urgent thing that is happening* — and the panel says the rest.
///
/// WHAT IT DRAWS, AND WHY IDLE IS GREY
/// The colour is the lamp's own, from `StatusPalette`, so the icon and a row
/// never disagree about what amber means. `idle` is the exception and it is
/// drawn as a hollow monochrome ring: dim red works in the column because it
/// sits among a dozen others and reads as *this one is resting*, but alone
/// beside the clock a red dot reads as a fault. A ring that follows the menu
/// bar's own light says *nothing is happening* without claiming anything is
/// wrong, and it is the shape the icon spends most of the day in.
///
/// WHY A TIMER AND NOT AN ANIMATION
/// `NSStatusItem` has no animation of its own; the button draws an image and
/// that is all. So the blink is a timer that swaps two images. It runs only
/// while there is something to blink about, because a repeating timer that
/// wakes the process twice a second all day would be this app's largest cost by
/// a wide margin, and it would be spent on a still picture.
/// `NSObject` because `target`/`action` is Objective-C dispatch: a pure Swift
/// class compiles fine here and then does nothing when the button is pressed,
/// which is the kind of failure that reaches a person rather than a build log.
@MainActor
final class MenuBarLamp: NSObject {

    /// Half a period. The panel's dot fades over 1.05 s and back; a menu bar
    /// icon cannot fade, so it alternates at the same rate. Slower than the dot
    /// would read as a different signal, faster as an alarm.
    private static let blinkInterval: TimeInterval = 0.525

    /// The drawn size. The menu bar gives about 22 points and expects an icon to
    /// leave room around itself; 14 is what the system's own round glyphs use.
    private static let lampSize: CGFloat = 14

    private var item: NSStatusItem?
    private var blinkTimer: Timer?
    private var dimmed = false
    private var summary: MenuBarSummary = .empty

    /// Called when the lamp is clicked with the left button.
    var onToggle: (() -> Void)?
    /// Called when it is clicked with the right button, or control-clicked.
    var onContextMenu: ((NSStatusBarButton) -> Void)?

    // MARK: - Presence

    /// `true` when the lamp is in the menu bar right now.
    var isVisible: Bool { item != nil }

    /// The button, for anchoring the drop-down under it. `nil` when the lamp is
    /// not shown, which is exactly when there is nothing to hang a drop-down on.
    var anchorButton: NSStatusBarButton? { item?.button }

    /// Where the lamp actually landed, in screen coordinates.
    var frameOnScreen: CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Whether the system is drawing this lamp where somebody could click it.
    ///
    /// `isVisible` cannot answer this and does not claim to: it reports what was
    /// asked for. A menu bar with no room left says yes to every request and
    /// draws none of them, which is why the question is answered from the
    /// geometry instead — see `MenuBarPlacement`.
    var placement: MenuBarPlacement.Verdict {
        guard let frame = frameOnScreen else { return .notYetPlaced }
        // The screen the lamp is on, which is the one carrying the menu bar it
        // was put in — not necessarily `NSScreen.main`, and on a two-screen desk
        // asking the wrong one would compare a frame against another display's
        // notch.
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return MenuBarPlacement.verdict(lamp: frame, in: screen?.auxiliaryTopRightArea)
    }

    func show() {
        guard item == nil else { return }
        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // `variableLength` because the count sits beside the lamp when more than
        // one row is in the loudest state, and a fixed width would either clip it
        // or leave a hole for the days it is not there.
        // NOT `.removalAllowed`. A lamp somebody can command-drag out of the bar
        // is a lamp that can be removed while the panel lives under it, and then
        // nothing on the machine can bring the panel back — the exact stranding
        // the *Hide this lamp* entry refuses, reachable by a gesture that gives no
        // warning and asks nothing. Hiding it has a door, and that door knows when
        // to say no.
        created.behavior = []
        if let button = created.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        item = created
        Diagnostics.log("menu bar lamp shown")
        render()
    }

    func hide() {
        guard let item else { return }
        stopBlinking()
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        Diagnostics.log("menu bar lamp hidden")
    }

    // MARK: - What it shows

    func update(_ next: MenuBarSummary) {
        guard next != summary else { return }
        summary = next
        render()
    }

    private func render() {
        guard let button = item?.button else { return }
        button.image = Self.image(for: summary, dimmed: false)
        // The number only when it counts something that wants a person, and only
        // when there is more than one of it.
        //
        // Both halves were learned by looking. `1` beside every lamp all day is
        // noise that teaches people to stop reading the number; and the first
        // build showed `6` next to a resting ring, because six projects were
        // idle — a count of things asking for nothing, in the one place on the
        // screen where space is scarcest.
        button.title = summary.needsAttention && summary.count > 1 ? " \(summary.count)" : ""
        button.toolTip = summary.tooltip
        summary.blinks ? startBlinking() : stopBlinking()
    }

    // MARK: - Blinking

    private func startBlinking() {
        guard blinkTimer == nil else { return }
        dimmed = false
        let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so it keeps blinking while a menu is open or the panel is
        // being dragged: those put the run loop in a tracking mode, and a timer
        // on the default mode alone stops dead for as long as that lasts.
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard dimmed, let button = item?.button else { return }
        dimmed = false
        button.image = Self.image(for: summary, dimmed: false)
    }

    private func tick() {
        guard let button = item?.button else { return }
        dimmed.toggle()
        button.image = Self.image(for: summary, dimmed: dimmed)
    }

    // MARK: - Drawing

    /// The lamp, drawn at the size the menu bar wants.
    ///
    /// Not a template when it carries a colour: a template image is recoloured
    /// by AppKit to match the menu bar, which would throw away the one thing the
    /// icon is for. It *is* a template when the column is at rest, so the ring
    /// follows a light menu bar and a dark one without this code knowing which
    /// it is in.
    static func image(for summary: MenuBarSummary, dimmed: Bool) -> NSImage {
        let side = lampSize
        let size = NSSize(width: side, height: side)

        guard let status = summary.lamp, status != .idle else {
            let ring = NSImage(size: size, flipped: false) { rect in
                let inset = rect.insetBy(dx: 1.5, dy: 1.5)
                NSColor.black.setStroke()
                let path = NSBezierPath(ovalIn: inset)
                path.lineWidth = 1.6
                path.stroke()
                return true
            }
            ring.isTemplate = true
            return ring
        }

        let colour = NSColor(StatusPalette.color(for: status))
        // The dim half of the blink. 0.28 rather than the dot's 0.25 because a
        // menu bar sits on an unknown background and the darker half of the cycle
        // has to stay visible on a light one.
        let alpha: CGFloat = dimmed ? 0.28 : 1
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            colour.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: inset).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - The click

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            onContextMenu?(sender)
        } else {
            onToggle?()
        }
    }

    deinit {
        blinkTimer?.invalidate()
    }
}
