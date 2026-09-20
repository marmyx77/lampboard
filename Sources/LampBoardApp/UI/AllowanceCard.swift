import LampBoardCore
import SwiftUI

/// One account's allowance, drawn as a card.
///
/// The strip at the foot of the column has room for one fact — the session window
/// and when it comes back. This is where the rest lives, and it is a card rather
/// than a paragraph for the reason `TooltipCard` is one: a tooltip that arrives as
/// sentences joined by newlines gives the eye nothing to hold, and the figure that
/// moves while you work reads in the same voice as the address that never changes.
///
/// It borrows `TooltipCard`'s grammar on purpose — small monospaced labels in a
/// left column, values in a grid that lines up, a bar under the one thing with a
/// shape — because the two cards appear in the same place, a second apart, and a
/// second layout for the second subject would read as a different application.
///
/// What it does not borrow is `RowSummary`. That type is shaped for a session: a
/// state, a last message, a keyboard legend. An allowance has none of those, and
/// filling them with blanks to reuse the view would put a status word on a thing
/// that has no status.
struct AllowanceCard: View {
    let report: AllowanceReport
    /// Fixed and passed in, like the row card's: the window is sized before it is
    /// shown, so a width that depended on the content would make every tooltip a
    /// different shape.
    let width: CGFloat
    /// Reference moment for the countdowns, so every line of one card agrees.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            grid.padding(.top, 9)
            separator
            Text("read \(ShortSpan.label(seconds: now.timeIntervalSince(report.limits.readAt))) ago")
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.42))
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Head

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                // The dot takes the colour of the limit that is furthest along, so
                // the card says at a glance what the strip said in a bar.
                Circle()
                    .fill(StatusPalette.allowanceColor(percent: highest))
                    .frame(width: 8, height: 8)

                Text(report.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("read on \(report.machine)")
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.55))
                .lineLimit(1)
                .padding(.leading, 15)
        }
    }

    // MARK: - The grid

    private var grid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(report.limits.limits, id: \.label) { limit in
                GridRow(alignment: .firstTextBaseline) {
                    Text(limit.label.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .kerning(0.5)
                        .foregroundStyle(Color.primary.opacity(0.38))
                        .gridColumnAlignment(.leading)

                    VStack(alignment: .leading, spacing: 3) {
                        (
                            Text("\(limit.percent)%")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundColor(Color.primary.opacity(0.92))
                            + Text("  \(reset(limit))")
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundColor(Color.primary.opacity(0.5))
                        )
                        .fixedSize(horizontal: false, vertical: true)

                        GeometryReader { space in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.13))
                                Capsule()
                                    .fill(StatusPalette.allowanceColor(percent: limit.percent))
                                    .frame(
                                        width: max(3, space.size.width * CGFloat(limit.percent) / 100)
                                    )
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    // MARK: - Internal

    /// The limit furthest along, which is what the header's dot reports.
    private var highest: Int {
        report.limits.limits.map(\.percent).max() ?? 0
    }

    /// When this one starts again, in the column's own shorthand.
    private func reset(_ limit: AccountLimits.Limit) -> String {
        guard let resetsAt = limit.resetsAt else { return "no reset" }
        let remaining = resetsAt.timeIntervalSince(now)
        // A window whose reset has passed is a figure about to be replaced, not a
        // negative countdown.
        return remaining > 0 ? "resets in \(ShortSpan.label(seconds: remaining))" : "resetting"
    }
}
