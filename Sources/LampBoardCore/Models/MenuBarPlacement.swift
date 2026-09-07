import CoreGraphics
import Foundation

/// Whether the lamp the system agreed to show is a lamp anybody can see.
///
/// WHY THIS QUESTION HAS TO BE ASKED AT ALL
/// `NSStatusItem` has no way of failing. Ask for one on a menu bar with no room
/// left and you are given an item, its `isVisible` answers `true`, its button
/// has a window, and that window has a frame — and nothing is drawn. Measured on
/// a 14-inch MacBook with a full bar: twenty-six items created in one process,
/// twenty-six reported visible, **zero** of them on screen.
///
/// That is not a curiosity when the panel lives in the menu bar, because then the
/// lamp is the only thing that can open it. A lamp nobody can see is a panel
/// nobody can reach: the app is running, its server answers, and every gesture a
/// person knows does nothing. Reported exactly that way — *it doesn't start any
/// more*.
///
/// WHAT SEPARATES THE DRAWN FROM THE UNDRAWN
/// On a notched screen the system reports two usable strips, one either side of
/// the notch (`NSScreen.auxiliaryTopLeftArea` / `…TopRightArea`). Status items
/// live in the right-hand one. When they stop fitting, the frames keep being
/// handed out to the left of it — into the notch first, then across the menu
/// titles, then off the edge of the screen: 809, 755, 711 … down to −345, all of
/// them "visible", none of them drawn.
///
/// So the honest test is not *does it have a frame* but *is that frame inside the
/// strip the system said status items live in*. On the machine this was written
/// on the strip starts at x=848 and the lamp landed at 809 — thirty-nine points
/// of difference between a feature and a dead end.
///
/// WHY A THIRD ANSWER
/// The frame is not laid out at once. Measured on the same machine: at creation
/// and on the next run-loop turn it is `(0, 0, 28, 0)` — zero height, no
/// position — and it settles about three tenths of a second later. A checker that
/// only knew *yes* and *no* would read that as *no* and move somebody's panel out
/// of the menu bar for no reason, which is a worse failure than the one it is
/// there to prevent: it would happen to everybody, every launch.
public enum MenuBarPlacement {

    /// What can be said about where a lamp ended up.
    public enum Verdict: Equatable, Sendable {
        /// Drawn where a pointer can reach it.
        case reachable
        /// Given a frame the system will not draw. The panel needs another door.
        case unreachable
        /// Not laid out yet. Ask again rather than concluding anything.
        case notYetPlaced
    }

    /// - Parameters:
    ///   - lamp: the frame of the lamp's own window, in screen coordinates.
    ///   - usable: the strip status items live in — `auxiliaryTopRightArea` of
    ///     the screen carrying the menu bar. `nil` on a screen with no notch,
    ///     which is not evidence of anything: the system offers no equivalent
    ///     there, and a rule that guessed would be moving panels on a hunch.
    public static func verdict(lamp: CGRect, in usable: CGRect?) -> Verdict {
        // Zero height is the shape of an item the window server has not placed
        // yet, not the shape of one it refused.
        guard lamp.width > 0, lamp.height > 0 else { return .notYetPlaced }
        guard let usable else { return .reachable }
        return lamp.minX >= usable.minX && lamp.maxX <= usable.maxX
            ? .reachable
            : .unreachable
    }
}
