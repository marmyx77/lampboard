import Foundation
import CoreGraphics

/// Where the panel hangs, and why it hangs from the top.
///
/// A column grows downward as sessions appear and shrinks as they end, so one of
/// its two horizontal edges has to be the fixed one. It is the top, for the
/// reason the panel exists: the eye goes to a known place to see whether
/// anything needs it, and a place that moves every time somebody opens a project
/// is not a known place.
///
/// Remembering the wrong edge is what made it walk. The position kept across
/// launches was the **bottom** left, while every resize held the **top** still:
/// the panel came back 65 points tall at the remembered bottom, grew nearly
/// seven hundred points downward from there, and saved that. One launch moved it
/// most of a screen; a few moved it off the bottom, where the rows that mattered
/// were the ones underneath the edge.
///
/// Everything here is in Cocoa coordinates, where `y` grows upward and
/// `visible.maxY` is the top of what a screen actually shows — already below the
/// menu bar, which is what makes hanging from it the same thing as hanging from
/// the menu bar.
public enum PanelPlacement {

    /// How close to the top counts as being attached to it.
    ///
    /// Wide enough that putting the panel up there by hand lands on it, narrow
    /// enough that a position chosen a little lower is respected rather than
    /// corrected.
    public static let snapDistance: CGFloat = 12

    /// The gap kept from the side of the screen. None is kept from the top: the
    /// panel is meant to hang off the menu bar.
    public static let sideMargin: CGFloat = 16

    /// The edge worth remembering: the left of the frame and its **top**.
    public static func anchor(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.maxY)
    }

    /// The anchor for the same panel at a new width: the edge nearest the side
    /// of the screen stays where it is, so a panel kept at the right grows to
    /// the left, toward the middle (UX §1), instead of off the screen.
    public static func anchor(widening frame: CGRect, to width: CGFloat, in visible: CGRect) -> CGPoint {
        guard width != frame.width else { return anchor(of: frame) }
        let x = frame.midX > visible.midX ? frame.maxX - width : frame.minX
        return CGPoint(x: x, y: frame.maxY)
    }

    /// Where the panel goes when nothing has been remembered: hung from the menu
    /// bar, at the right.
    public static func defaultAnchor(size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - size.width - sideMargin, y: visible.maxY)
    }

    /// The frame of a panel of this size hung from that anchor, kept **whole**
    /// inside what the screen shows.
    ///
    /// Clamped rather than merely checked for overlap. The old rule asked
    /// whether the frame touched a screen at all, which a panel hanging one
    /// pixel over the edge passes while showing almost nothing.
    ///
    /// A panel taller than the screen hangs from the top and is left long: the
    /// caller bounds the height, and cutting it here as well would mean two
    /// places deciding one thing.
    public static func frame(hangingFrom anchor: CGPoint, size: CGSize, in visible: CGRect) -> CGRect {
        let x = min(max(anchor.x, visible.minX), max(visible.maxX - size.width, visible.minX))
        var top = min(anchor.y, visible.maxY)
        if abs(top - visible.maxY) <= snapDistance { top = visible.maxY }
        // The bottom may not sink below the screen — unless the panel is taller
        // than the screen, where hanging from the top is the only answer that
        // shows the rows nearest the top.
        top = max(top, min(visible.minY + size.height, visible.maxY))
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}
