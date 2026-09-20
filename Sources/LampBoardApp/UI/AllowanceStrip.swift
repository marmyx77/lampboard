import LampBoardCore
import SwiftUI

/// How much of the account's allowance is gone, at the foot of the column.
///
/// **One line per account, and that is the whole design constraint.** The first
/// version drew a labelled bar for each of the three limits — four lines per
/// account, eight for somebody signed into two — on a panel two hundred and forty
/// points wide, in eight-and-a-half point type. It buried the column it was meant
/// to annotate: with seven projects open, three of them went off the bottom. The
/// figures were right and the thing was unusable, which is the worse of the two
/// failures, and it survived a review because the review checked the numbers
/// instead of looking at the panel.
///
/// So the strip answers one question — *when does the work stop, and when does it
/// start again* — in one line each: **the session limit and its reset**.
///
/// Not "whichever is highest", which was the second version and was arbitrary: a
/// weekly figure sitting at 32% is not news, and showing it instead of the
/// five-hour window meant the one number a person can act on kept disappearing
/// behind one they cannot. The five-hour window is the one that stops the work
/// today and comes back this afternoon.
///
/// The exception is the case where that stops being true. When another limit is
/// genuinely **spent**, it is the binding one — the session window resetting in
/// forty minutes buys nothing if the week is gone — so that one takes the line
/// instead. Everything else is a hover away, exactly as it is for a project row.
///
/// Bars rather than rings, still: the ring beside each row already means how full
/// one conversation's context window is, and a second ring meaning something else
/// would read as the same measurement about a different subject.
///
/// The bar carries the **lamps' own three hues** — green below forty, yellow to
/// seventy-five, red above — because that grammar is already learned a foot up the
/// panel and a second one for the same idea would be two to learn. What keeps the
/// lamps first is volume, not palette: five points of bar at eighty-five percent
/// against a saturated disc of thirteen.
struct AllowanceStrip: View {
    /// One line per account. More than one is the ordinary case for anybody whose
    /// laptop and build box are signed in differently.
    let reports: [AllowanceReport]
    /// Why there is nothing, when there is nothing.
    let quiet: String?
    let compact: Bool

    /// Whether to name the account. Off with a single one, where the address is a
    /// line of text telling the person what they already know; on the moment there
    /// are two, where leaving it off is what made the figure wrong in the first
    /// place (D47).
    private var namesAccounts: Bool { reports.count > 1 }

    var body: some View {
        if !reports.isEmpty {
            VStack(spacing: 2) {
                ForEach(reports, id: \.label) { report in
                    line(report)
                }
            }
            .padding(.horizontal, Layout.panelPadding)
            .padding(.bottom, 4)
        } else if let quiet, !compact {
            // A sentence, not an empty space: silence with no explanation reads as
            // a broken feature, and the commonest reason — a sign-in that aged out
            // — is not something the person did wrong.
            Text(quiet)
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.38))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.panelPadding)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func line(_ report: AllowanceReport) -> some View {
        if let limit = shown(in: report) {
            HStack(spacing: 6) {
                if namesAccounts && !compact {
                    // The local part alone. The domain is the half that repeats.
                    Text(shortName(report.label))
                        .font(Self.face)
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 58, alignment: .leading)
                }

                // Named **only when it is not the session window**, which is the
                // rare case. Writing "session" on every line spends a third of the
                // width on a word that is almost always the same one — and the day
                // it changes, the label appearing is itself the signal.
                if !compact, limit.span != .session {
                    Text(limit.label)
                        .font(Self.face)
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .lineLimit(1)
                }

                track(limit)

                if !compact {
                    // Fixed widths, right-aligned, so the two lines make a column
                    // instead of two ragged sentences. Monospaced digits so the
                    // figures do not shuffle sideways as they change.
                    Text("\(limit.percent)%")
                        .font(Self.face.monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.70))
                        .frame(width: 34, alignment: .trailing)

                    Text(reset(limit))
                        .font(Self.face.monospacedDigit())
                        .foregroundStyle(StatusPalette.timeColor)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .frame(height: Layout.allowanceLine)
            .contentShape(Rectangle())
            // The panel's own tooltip, **not** `.help(…)`: this window is never
            // key, and the system one shows nothing in it. `Tooltip` says so in as
            // many words, and the first version of this strip used `.help` anyway —
            // so hovering a line did nothing at all, which is how the other two
            // limits came to be unreachable.
            .tooltip(report)
        }
    }

    /// Above this a limit counts as spent, and takes the line from the session
    /// window. Not 100: a week at 94% will stop the work before it resets, and a
    /// strip that waited for the round number would tell somebody at the moment it
    /// stopped being useful.
    private static let spent = 90

    /// The session window, unless something else is spent.
    private func shown(in report: AllowanceReport) -> AccountLimits.Limit? {
        let limits = report.limits.limits
        let binding = limits
            .filter { $0.span != .session && $0.percent >= Self.spent }
            .max { $0.percent < $1.percent }
        return binding ?? limits.first { $0.span == .session } ?? limits.max { $0.percent < $1.percent }
    }

    /// The row's own face. Asked for in those words: the strip was set two sizes
    /// smaller than the projects above it and read as a footnote to them, when it
    /// is the one line that says how long the whole column has left.
    private static let face = Font.system(size: 12, weight: .regular, design: .rounded)

    /// How long until this limit starts again, in the column's own shorthand.
    private func reset(_ limit: AccountLimits.Limit) -> String {
        guard let resetsAt = limit.resetsAt else { return "—" }
        let remaining = resetsAt.timeIntervalSince(Date())
        return remaining > 0 ? ShortSpan.label(seconds: remaining) : "now"
    }

    /// `editorial@aworld.org` → `editorial`. A machine name carries no `@` and is
    /// returned whole.
    private func shortName(_ label: String) -> String {
        label.split(separator: "@").first.map(String.init) ?? label
    }

    private func track(_ limit: AccountLimits.Limit) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(StatusPalette.allowanceColor(percent: limit.percent))
                    // A bar at 1% still has to read as a bar and not as a rounding
                    // error, or "barely started" and "nothing read yet" look alike.
                    .frame(width: max(geometry.size.width * CGFloat(limit.percent) / 100, 3))
            }
        }
        .frame(height: 5)
    }

}
