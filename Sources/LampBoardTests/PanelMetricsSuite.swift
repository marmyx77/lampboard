import LampBoardCore
import CoreGraphics
import TestKit

/// How tall the panel has to be for everything it draws to be visible.
///
/// These exist because the same defect was reported twice: an opened project
/// pushed the row under it behind the footer. The first time the window and the
/// column were two formulas; the second time they were two formulas again,
/// because only one of them had been corrected.
enum PanelMetricsSuite {

    /// Round numbers rather than the real ones, so a change to the look cannot
    /// silently rewrite what these cases assert.
    private static let sizes = PanelMetrics.Sizes(
        row: 20, subRow: 10, spacing: 2, blockInset: 3,
        tail: 16, padding: 8, footer: 25, issueStrip: 17
    )

    private static func block(
        rows: Int = 1, shown: Int = 0, tail: Bool = false, compact: Bool = false
    ) -> CGFloat {
        PanelMetrics.blockHeight(
            rowCount: rows, shownConversations: shown, hasTail: tail,
            compact: compact, sizes: sizes
        )
    }

    static let suite = TestSuite("Panel metrics", [

        TestCase("A project with one session is one row and nothing else") { t in
            t.expectEqual(block(), 20, "a row")
        },

        TestCase("A project holding several carries the block's inset, closed too") { t in
            // The inset is the whole bug. It is invisible with one project open
            // and it is half a row with two, which is exactly enough to cut the
            // last line of the column.
            t.expectEqual(block(rows: 3), 26, "twenty plus three above and three below")
        },

        TestCase("An opened project is as tall as what it shows") { t in
            // 20 + 3 conversations at 10 with a 2 point gap each + 6 of inset.
            t.expectEqual(block(rows: 3, shown: 3), 62, "row, three lines, inset")
        },

        TestCase("The tail is a line too") { t in
            t.expectEqual(block(rows: 9, shown: 6, tail: true) - block(rows: 9, shown: 6), 16,
                          "“and 3 more” takes room like anything else drawn")
        },

        TestCase("The narrow panel has no fill, so it has no inset") { t in
            t.expectEqual(block(rows: 3, compact: true), 20, "just the dot's row")
            t.expectEqual(block(rows: 3, shown: 2, compact: true), 44, "and its dots")
        },

        TestCase("Nothing caps the column but the caller") { t in
            // Twenty sessions is a real number on a real machine, and a column
            // that stopped at twelve rows would stop being the point. What bounds
            // this is the screen, and that is the caller's business.
            let twenty = Array(repeating: block(), count: 20)
            let five = Array(repeating: block(), count: 5)
            let grew = PanelMetrics.height(ofBlocks: twenty, extras: 0, showsIssue: false, sizes: sizes)
                - PanelMetrics.height(ofBlocks: five, extras: 0, showsIssue: false, sizes: sizes)
            t.expectEqual(grew, 15 * 22, "fifteen more rows, each with its gap")
        },

        TestCase("The service rows are counted, or the last one is clipped") { t in
            let bare = PanelMetrics.height(ofBlocks: [block()], extras: 0, showsIssue: false, sizes: sizes)
            let withSummary = PanelMetrics.height(ofBlocks: [block()], extras: 1, showsIssue: false, sizes: sizes)
            t.expectEqual(withSummary - bare, 22, "the hidden summary is a row with a gap")
        },

        TestCase("The issue strip adds its own height, and only while there is one") { t in
            let blocks = [block()]
            t.expectEqual(
                PanelMetrics.height(ofBlocks: blocks, extras: 0, showsIssue: true, sizes: sizes)
                    - PanelMetrics.height(ofBlocks: blocks, extras: 0, showsIssue: false, sizes: sizes),
                17, "the strip"
            )
        },

        TestCase("LampMaster's line is counted while it is switched on") { t in
            let blocks = [block()]
            t.expectEqual(
                PanelMetrics.height(ofBlocks: blocks, extras: 0, showsIssue: false, showsLampMaster: true, sizes: sizes)
                    - PanelMetrics.height(ofBlocks: blocks, extras: 0, showsIssue: false, sizes: sizes),
                17, "one strip's height"
            )
        },

        TestCase("The tutorial's band is counted line by line, and only in a trial") { t in
            let blocks = [block()]
            t.expectEqual(
                PanelMetrics.height(ofBlocks: blocks, extras: 0, showsIssue: false, tourLines: 3, sizes: sizes)
                    - PanelMetrics.height(ofBlocks: blocks, extras: 0, showsIssue: false, sizes: sizes),
                51, "three lines of seventeen points"
            )
        },

        TestCase("An empty column is still a panel") { t in
            // The chrome is 8 + 8 of padding and 25 of footer, and one row's worth
            // of room so the empty state has somewhere to be.
            t.expectEqual(
                PanelMetrics.height(ofBlocks: [], extras: 0, showsIssue: false, sizes: sizes),
                20 + 16 + 25, "chrome and one row"
            )
        },
    ])
}
