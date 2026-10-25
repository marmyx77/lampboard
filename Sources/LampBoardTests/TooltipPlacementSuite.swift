#if canImport(CoreGraphics)
import CoreGraphics
#else
// Linux: Foundation carries the same geometry types.
import Foundation
#endif
import LampBoardCore
import TestKit

/// Where a row's card goes: beside the panel it explains, never over it (U1).
///
/// Cocoa coordinates, as the app hands them: the origin is bottom-left, so the top
/// of the screen is the larger y.
enum TooltipPlacementSuite {

    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static let card = CGSize(width: 318, height: 160)

    static func overlaps(_ origin: CGPoint, _ panel: CGRect) -> Bool {
        CGRect(origin: origin, size: card).intersects(panel)
    }

    static let suite = TestSuite("Tooltip placement", [

        TestCase("Beside the panel, on the right when there is room, the top level with the pointer") { t in
            let panel = CGRect(x: 200, y: 300, width: 340, height: 500)
            let pointer = CGPoint(x: 300, y: 700)
            let origin = TooltipPlacement.origin(size: card, anchor: panel, pointer: pointer, screen: screen)
            t.expectEqual(origin.x, panel.maxX + TooltipPlacement.gap)
            t.expectEqual(origin.y + card.height, pointer.y + TooltipPlacement.lift)
            t.expect(!overlaps(origin, panel), "beside, not over")
        },

        TestCase("On the left when the panel sits against the right edge: the menu-bar case that clipped") { t in
            let panel = CGRect(x: 1090, y: 375, width: 340, height: 480)
            let origin = TooltipPlacement.origin(size: card, anchor: panel,
                                                 pointer: CGPoint(x: 1200, y: 800), screen: screen)
            t.expectEqual(origin.x, panel.minX - TooltipPlacement.gap - card.width)
            t.expect(!overlaps(origin, panel), "never under or over the rows it explains")
        },

        TestCase("No room on either side: under the panel, else above it") { t in
            let wide = CGRect(x: 300, y: 400, width: 900, height: 300)
            let below = TooltipPlacement.origin(size: card, anchor: wide, pointer: CGPoint(x: 600, y: 600), screen: screen)
            t.expectEqual(below.y, wide.minY - TooltipPlacement.gap - card.height)
            t.expect(!overlaps(below, wide), "under")
            let low = CGRect(x: 300, y: 40, width: 900, height: 600)
            let above = TooltipPlacement.origin(size: card, anchor: low, pointer: CGPoint(x: 600, y: 300), screen: screen)
            t.expectEqual(above.y, low.maxY + TooltipPlacement.gap)
            t.expect(!overlaps(above, low), "above")
        },

        TestCase("Kept on the screen: a pointer near the top or the bottom does not push it off") { t in
            let panel = CGRect(x: 200, y: 0, width: 340, height: 875)
            let top = TooltipPlacement.origin(size: card, anchor: panel, pointer: CGPoint(x: 300, y: 870), screen: screen)
            t.expectEqual(top.y + card.height, screen.maxY)
            let bottom = TooltipPlacement.origin(size: card, anchor: panel, pointer: CGPoint(x: 300, y: 10), screen: screen)
            t.expectEqual(bottom.y, screen.minY)
        },

        TestCase("In the Hub, beside the row: a window wider than its rows keeps the card next to what is read") { t in
            // The Hub reuses the panel's rows in its sidebar. Beside the whole
            // window, the card opened past the Hub's right edge, a screen away
            // from the row (25 October 2026).
            let hub = CGRect(x: 100, y: 80, width: 1200, height: 760)
            let row = CGRect(x: 100, y: 600, width: 280, height: 44)
            let anchor = TooltipPlacement.anchor(window: hub, item: row, besideWindow: false)
            let origin = TooltipPlacement.origin(size: card, anchor: anchor, pointer: CGPoint(x: 200, y: 620), screen: screen)
            t.expectEqual(origin.x, row.maxX + TooltipPlacement.gap)
            t.expect(hub.contains(CGRect(origin: origin, size: card)), "over the Hub's own centre, next to the row")
            t.expect(!overlaps(origin, row), "never over the row it explains")
        },

        TestCase("In the panel, beside the panel: its rows are the window, and a control's card stays off it") { t in
            let panel = CGRect(x: 200, y: 300, width: 340, height: 500)
            let button = CGRect(x: 220, y: 760, width: 24, height: 24)
            t.expectEqual(TooltipPlacement.anchor(window: panel, item: button, besideWindow: true), panel)
            t.expectEqual(TooltipPlacement.anchor(window: panel, item: nil, besideWindow: false), panel,
                          "nothing said which view: the window")
        },

        TestCase("A second screen: the card stays on the one the panel is on") { t in
            let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            let panel = CGRect(x: 2500, y: 200, width: 340, height: 600)
            let origin = TooltipPlacement.origin(size: card, anchor: panel, pointer: CGPoint(x: 2600, y: 600), screen: right)
            t.expectEqual(origin.x, panel.maxX + TooltipPlacement.gap)
            t.expect(right.contains(CGRect(origin: origin, size: card)), "on the panel's screen")
        },
    ])
}
