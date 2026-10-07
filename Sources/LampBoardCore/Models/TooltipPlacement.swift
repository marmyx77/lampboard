import CoreGraphics
import Foundation

/// Where a card that explains something in the panel goes: **beside the panel,
/// never over it** (U1).
///
/// The first rule put it below and to the right of the pointer. The pointer is
/// always inside the panel, so whenever the card turned to the left — a panel near
/// the right edge, the ordinary place for one living in the menu bar — its right
/// edge fell fourteen points inside the panel, and in the menu bar the panel sits a
/// window level above an ordinary floating window, so the card went *under* it and
/// came out cut. Measured on the test Mac on 7 October 2026.
///
/// So the card is anchored to the panel's edge, not to the pointer: on the right
/// when it fits, else on the left, else under the panel, else above it. Only its
/// height follows the pointer, so the card starts level with the row being read.
/// Cocoa coordinates: the origin is bottom-left.
public enum TooltipPlacement {

    /// Between the panel's edge and the card.
    public static let gap: CGFloat = 8
    /// How far above the pointer the card's top sits: about half a row, so the
    /// card's first line is level with the row's name rather than below it.
    public static let lift: CGFloat = 12

    /// - Parameters:
    ///   - size: the card, already measured.
    ///   - anchor: the frame of the window being explained.
    ///   - pointer: where the pointer is.
    ///   - screen: the visible frame of the screen the window is on.
    public static func origin(size: CGSize, anchor: CGRect, pointer: CGPoint, screen: CGRect) -> CGPoint {
        let right = anchor.maxX + gap
        let left = anchor.minX - gap - size.width
        if right + size.width <= screen.maxX {
            return CGPoint(x: right, y: levelWithPointer(size, pointer, screen))
        }
        if left >= screen.minX {
            return CGPoint(x: left, y: levelWithPointer(size, pointer, screen))
        }
        let x = clamp(anchor.minX, screen.minX, screen.maxX - size.width)
        let below = anchor.minY - gap - size.height
        if below >= screen.minY { return CGPoint(x: x, y: below) }
        let above = anchor.maxY + gap
        if above + size.height <= screen.maxY { return CGPoint(x: x, y: above) }
        // A window filling the screen leaves nowhere that is not over it. The
        // pointer's side of the screen at least keeps the card off the row read.
        return CGPoint(x: x, y: levelWithPointer(size, pointer, screen))
    }

    private static func levelWithPointer(_ size: CGSize, _ pointer: CGPoint, _ screen: CGRect) -> CGFloat {
        clamp(pointer.y + lift - size.height, screen.minY, screen.maxY - size.height)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}
