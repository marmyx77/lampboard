import CoreGraphics
import Foundation

/// How tall the panel has to be to draw what it is drawing.
///
/// **In Core because it bit twice.** The window sized itself from one formula
/// while the column laid the rows out with another, and the two agreed right up
/// until a project could be opened: then they differed by the padding a block
/// adds, the window came up short, and the last row was cut in half. The first
/// repair corrected one of the two formulas, which is how the same defect was
/// reported a second time.
///
/// Arithmetic that decides whether a row can be seen is not drawing, and it
/// belongs where a test can call it.
public enum PanelMetrics {

    /// The measurements the panel draws with. Defaults are the real ones; the
    /// tests pass their own so a change to the look cannot silently rewrite what
    /// the cases are asserting.
    public struct Sizes: Sendable, Equatable {
        public let row: CGFloat
        public let subRow: CGFloat
        public let spacing: CGFloat
        public let blockInset: CGFloat
        public let tail: CGFloat
        public let padding: CGFloat
        public let footer: CGFloat
        public let issueStrip: CGFloat
        /// One line of the allowance strip, drawn once per signed-in account.
        public let allowanceLine: CGFloat
        /// A permission or question the panel holds, drawn under its row with
        /// Allow and Deny (U2), in place of the queue's card above the rows.
        public let inlineAsk: CGFloat
        /// A project's row in the wide panel, which carries a second line (D76);
        /// `nil` where it is as tall as the narrow one.
        public let wideRow: CGFloat?

        public init(
            row: CGFloat, subRow: CGFloat, spacing: CGFloat, blockInset: CGFloat,
            tail: CGFloat, padding: CGFloat, footer: CGFloat, issueStrip: CGFloat,
            allowanceLine: CGFloat = 0, inlineAsk: CGFloat = 0, wideRow: CGFloat? = nil
        ) {
            self.inlineAsk = inlineAsk
            self.wideRow = wideRow
            self.row = row
            self.subRow = subRow
            self.spacing = spacing
            self.blockInset = blockInset
            self.tail = tail
            self.padding = padding
            self.allowanceLine = allowanceLine
            self.footer = footer
            self.issueStrip = issueStrip
        }
    }

    /// How tall one row draws, including the conversations it is showing.
    ///
    /// A project holding several conversations is drawn inside a block, and the
    /// fill that makes it a block takes an inset above and below. That inset is
    /// the whole of the bug this function exists to prevent: it is invisible
    /// until two projects are open, and then it is half a row.
    ///
    /// The narrow panel has no fill, so it has no inset.
    /// - Parameter asks: an ask the panel holds for this row, drawn under it
    ///   (U2). Only in the wide panel: the narrow one has no room for buttons.
    public static func blockHeight(
        rowCount: Int,
        shownConversations: Int,
        hasTail: Bool,
        compact: Bool,
        asks: Bool = false,
        sizes: Sizes
    ) -> CGFloat {
        let inset = (!compact && rowCount > 1) ? sizes.blockInset * 2 : 0
        let row = (compact ? sizes.row : (sizes.wideRow ?? sizes.row)) + (asks && !compact ? sizes.inlineAsk : 0)
        guard shownConversations > 0 else { return row + inset }
        return row
            + CGFloat(shownConversations) * (sizes.subRow + sizes.spacing)
            + (hasTail ? sizes.tail : 0)
            + inset
    }

    /// The whole panel, given every block it draws.
    ///
    /// **Nothing caps it but the screen**, and the caller is what clamps it. A
    /// fixed ceiling of twelve rows was the first answer and it was wrong twice:
    /// it hid the rows under an opened project, and there are people with twenty
    /// sessions open, for whom a column that stops at twelve stops being the
    /// point.
    /// - Parameter allowanceLines: how many accounts the allowance strip is
    ///   drawing, zero when the switch is off. **It has to be counted here**, and
    ///   forgetting it is not a cosmetic slip: the window is sized from this
    ///   number, so a strip the calculation does not know about does not make the
    ///   panel taller — it takes the room from the rows, and the projects at the
    ///   bottom of the column simply go off the end. Reported in exactly those
    ///   terms the first time the strip shipped.
    /// - Parameter showsLampMaster: LampMaster's line in the narrow panel, while
    ///   it is switched on. One line the height of the issue strip, counted for the
    ///   same reason as the allowance: uncounted, it takes the last row's room. In
    ///   the wide panel LampMaster is a star in the bar (U2) and costs nothing here.
    /// - Parameter tourLines: the tutorial's band in a trial, in lines of the
    ///   issue strip's height; zero everywhere else.
    /// - Parameter resting: the line of rows at rest (U2), and the rows listed
    ///   under it while it is open, one plain line each.
    public static func height(
        ofBlocks blocks: [CGFloat], extras: Int, showsIssue: Bool,
        allowanceLines: Int = 0, showsLampMaster: Bool = false, tourLines: Int = 0,
        resting: (shown: Bool, open: Int) = (false, 0), bar: CGFloat = 0, sizes: Sizes
    ) -> CGFloat {
        let restingLines = (resting.shown ? 1 : 0) + resting.open
        let all = blocks + Array(repeating: sizes.row, count: extras + restingLines)
        let content = all.reduce(0, +) + CGFloat(max(all.count - 1, 0)) * sizes.spacing
        let allowance = allowanceLines > 0
            ? CGFloat(allowanceLines) * sizes.allowanceLine
                + CGFloat(allowanceLines - 1) * 2
                + 4
            : 0
        return max(content, sizes.row)
            + sizes.padding * 2 + sizes.footer + (showsIssue ? sizes.issueStrip : 0) + allowance
            + (showsLampMaster ? sizes.issueStrip : 0)
            + CGFloat(tourLines) * sizes.issueStrip
            + bar
    }

    /// The bar at the top of the wide panel (D77): a padding above it, its field,
    /// and under it, while something is typed, the results and LampMaster's
    /// answer, each after a gap. The answer has a fixed height and scrolls: the
    /// panel cannot measure text it has not drawn.
    public static func barHeight(field: CGFloat, results: Int, resultRow: CGFloat, answer: CGFloat, sizes: Sizes) -> CGFloat {
        sizes.padding + field
            + (results > 0 ? sizes.spacing + CGFloat(results) * resultRow : 0)
            + (answer > 0 ? sizes.spacing + answer : 0)
    }
}
