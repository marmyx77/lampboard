import LampBoardCore
import Foundation
import TestKit

/// Where the panel hangs across a launch, a growth and a screen that changed.
///
/// The case that matters is the first one: it is the regression test for a panel
/// that walked off the bottom of the screen one launch at a time, and it fails
/// against the rule that used to be in force.
enum PanelPlacementSuite {

    /// A 2560×1080 screen with the menu bar taken off the top.
    private static let visible = CGRect(x: 0, y: 0, width: 2560, height: 1043)
    private static let width: CGFloat = 240

    static let suite = TestSuite("Panel placement", [

        TestCase("A launch and a growth put the panel back where it was") { t in
            // The ratchet, written down. The panel was 757 points tall when it
            // was last on screen; it comes back 65 tall while the first rows are
            // still arriving, and grows to 757 again. Holding the **top** still
            // means the three frames share it. Holding the bottom, which is what
            // was remembered before, dropped the top by 692 points every time.
            let hung = CGPoint(x: 2304, y: 1043)
            let atQuit = PanelPlacement.frame(
                hangingFrom: hung, size: CGSize(width: width, height: 757), in: visible
            )
            let atLaunch = PanelPlacement.frame(
                hangingFrom: PanelPlacement.anchor(of: atQuit),
                size: CGSize(width: width, height: 65), in: visible
            )
            let grown = PanelPlacement.frame(
                hangingFrom: PanelPlacement.anchor(of: atLaunch),
                size: CGSize(width: width, height: 757), in: visible
            )

            t.expectEqual(atLaunch.maxY, atQuit.maxY, "the top does not move while it is small")
            t.expectEqual(grown, atQuit, "and the panel comes back exactly where it was")
        },

        TestCase("Widening keeps the edge nearest the side of the screen: the panel grows toward the middle") { t in
            let right = CGRect(x: 2300, y: 600, width: 240, height: 400)
            t.expectEqual(PanelPlacement.anchor(widening: right, to: 340, in: visible), CGPoint(x: 2200, y: 1000),
                          "on the right half it grows to the left")
            let left = CGRect(x: 16, y: 600, width: 240, height: 400)
            t.expectEqual(PanelPlacement.anchor(widening: left, to: 340, in: visible), CGPoint(x: 16, y: 1000),
                          "on the left half it grows to the right")
            t.expectEqual(PanelPlacement.anchor(widening: right, to: 240, in: visible), PanelPlacement.anchor(of: right),
                          "the same width moves nothing")
        },

        TestCase("Nothing hangs below the bottom of the screen") { t in
            // What the old rule allowed: it asked whether the frame touched a
            // screen at all, and a panel hanging one pixel over the edge passes
            // that while showing almost nothing.
            let low = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 2304, y: 300),
                size: CGSize(width: width, height: 757), in: visible
            )
            t.expectEqual(low.minY, visible.minY, "pushed up rather than cut")
            t.expectEqual(low.height, 757, "and not shortened to fit")
            t.expect(visible.contains(low), "whole, inside what the screen shows")
        },

        TestCase("A panel taller than the screen hangs from the menu bar") { t in
            // The rows nearest the top are the ones worth showing: the caller
            // bounds the height, and this must not bound it a second time.
            let tall = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 2304, y: 400),
                size: CGSize(width: width, height: 2000), in: visible
            )
            t.expectEqual(tall.maxY, visible.maxY, "hung from the top")
            t.expectEqual(tall.height, 2000, "and left as long as it is")
        },

        TestCase("Close to the menu bar means attached to it") { t in
            let near = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 2304, y: visible.maxY - 8),
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expectEqual(near.maxY, visible.maxY, "eight points is attached")

            let deliberate = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 2304, y: visible.maxY - 200),
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expectEqual(deliberate.maxY, visible.maxY - 200,
                          "and a position chosen lower is left alone")
        },

        TestCase("Nothing hangs above the menu bar, or off either side") { t in
            let high = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 2304, y: visible.maxY + 400),
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expectEqual(high.maxY, visible.maxY, "the menu bar is the ceiling")

            let right = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 9000, y: visible.maxY),
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expectEqual(right.maxX, visible.maxX, "not past the right edge")

            let left = PanelPlacement.frame(
                hangingFrom: CGPoint(x: -900, y: visible.maxY),
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expectEqual(left.minX, visible.minX, "nor past the left one")
        },

        TestCase("With nothing remembered it hangs off the menu bar, at the right") { t in
            let anchor = PanelPlacement.defaultAnchor(
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expectEqual(anchor.y, visible.maxY, "against the menu bar")
            t.expectEqual(anchor.x, visible.maxX - width - PanelPlacement.sideMargin,
                          "and clear of the right edge")
        },

        TestCase("A screen that is gone is not a place") { t in
            // The external monitor case: the remembered anchor names a point no
            // screen has any more, and the panel has to come back somewhere it
            // can be seen rather than stay where it cannot.
            let orphan = PanelPlacement.frame(
                hangingFrom: CGPoint(x: 4000, y: 2400),
                size: CGSize(width: width, height: 300), in: visible
            )
            t.expect(visible.contains(orphan), "back on the screen that is still here")
        },
    ])
}
