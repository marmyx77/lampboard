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

        public init(
            row: CGFloat, subRow: CGFloat, spacing: CGFloat, blockInset: CGFloat,
            tail: CGFloat, padding: CGFloat, footer: CGFloat, issueStrip: CGFloat,
            allowanceLine: CGFloat = 0
        ) {
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
    public static func blockHeight(
        rowCount: Int,
        shownConversations: Int,
        hasTail: Bool,
        compact: Bool,
        sizes: Sizes
    ) -> CGFloat {
        let inset = (!compact && rowCount > 1) ? sizes.blockInset * 2 : 0
        guard shownConversations > 0 else { return sizes.row + inset }
        return sizes.row
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
    public static func height(
        ofBlocks blocks: [CGFloat], extras: Int, showsIssue: Bool,
        allowanceLines: Int = 0, sizes: Sizes
    ) -> CGFloat {
        let all = blocks + Array(repeating: sizes.row, count: extras)
        let content = all.reduce(0, +) + CGFloat(max(all.count - 1, 0)) * sizes.spacing
        let allowance = allowanceLines > 0
            ? CGFloat(allowanceLines) * sizes.allowanceLine
                + CGFloat(allowanceLines - 1) * 2
                + 4
            : 0
        return max(content, sizes.row)
            + sizes.padding * 2 + sizes.footer + (showsIssue ? sizes.issueStrip : 0) + allowance
    }
}
