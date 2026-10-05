import LampBoardCore
import SwiftUI

/// What the lights mean — and, in the same table, how many of each there are
/// right now.
///
/// WHY A LEGEND EXISTS AT ALL
/// The column started with three colours and needed no explanation. It now has
/// six, two of which differ only in brightness, plus a ring that is not a state
/// and a second ring that is not a light. That is past the point where a stranger
/// can infer it, and a panel whose grammar has to be explained by its author is a
/// panel with a missing page.
///
/// WHY IT IS ALSO A CENSUS
/// A key that only says "green means an unread answer" is read once and never
/// again. The same table with a live count beside each row answers a question
/// people actually have — *how many are waiting for me?* — and that is what makes
/// it worth opening a second time. The counts are of the rows the panel is
/// showing: hidden projects are not in them, for the same reason they are not in
/// the column.
struct LegendView: View {
    @ObservedObject var store: StateStore
    /// The rows as the panel is drawing them at this instant. A closure and not a
    /// value: preferences change what the column shows — grouping, the waiting
    /// filter, hidden projects — and a legend built from a snapshot would keep
    /// counting a column that no longer exists.
    let rendering: () -> ColumnRendering

    var body: some View {
        // `store.state` is read so that SwiftUI re-runs this body on every signal;
        // the counting itself goes through the same renderer the panel uses.
        _ = store.state
        let rows = rendering().rows

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("The lights") {
                    ForEach(SessionStatus.legendOrder, id: \.self) { status in
                        entry(
                            swatch: AnyView(
                                TrafficLightDot(status: status, calm: true).frame(width: 16)
                            ),
                            title: status.label,
                            detail: Self.meaning(of: status),
                            count: rows.filter { $0.status == status }.count
                        )
                    }
                }

                section("The light's shape") {
                    entry(
                        swatch: AnyView(TrafficLightDot(status: .working, calm: true, style: .stalled).frame(width: 16)),
                        title: "a dashed light",
                        detail: """
                            Working, but on the same tool for a quarter of an hour or more: \
                            a build that takes its time, or a command waiting on input. \
                            Its card names the tool and the line.
                            """,
                        count: rows.filter { $0.lampStyle(now: Date(), modInUse: true) == .stalled }.count
                    )
                    entry(
                        swatch: AnyView(TrafficLightDot(status: .ready, calm: true, style: .hollow).frame(width: 16)),
                        title: "a hollow light",
                        detail: """
                            A session the companion mod does not speak for, while other \
                            sessions have it: the colour comes from the hooks alone, and \
                            what needs the mod — exact context, cost, answering from here — \
                            is not there. Started before the mod was installed, usually.
                            """,
                        count: 0
                    )
                }

                section("The two rings") {
                    entry(
                        swatch: AnyView(
                            TrafficLightDot(status: .ready, calm: true, listening: true)
                                .frame(width: 16)
                        ),
                        title: "a ring around the light",
                        detail: """
                            Something is still listening behind that row: a monitor \
                            registered and not yet triggered. It is not a state of its \
                            own: the turn ended green, or red, and *besides that* an ear \
                            is open.
                            """,
                        count: rows.filter { $0.listeners > 0 }.count
                    )

                    entry(
                        swatch: AnyView(ContextRing(reading: Self.sample).frame(width: 16)),
                        title: "the ring with a letter in it",
                        detail: """
                            How full that session's context is, and which model is \
                            holding it: O for Opus, S for Sonnet, H for Haiku, F for \
                            Fable, M for Mythos, n for one this build does not know. A \
                            paler arc is a floor: at least this much. A dashed circle \
                            means nothing has been read from that session yet.
                            """,
                        count: rows.filter { $0.context?.percent != nil }.count
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Where the numbers come from")
                        .font(.system(size: 11, weight: .semibold))
                    Text(Self.provenance)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pieces

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func entry(
        swatch: AnyView, title: String, detail: String, count: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            swatch.padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // Zero is written out rather than left blank: "none right now" is an
            // answer, and an empty cell reads as a table that failed to fill in.
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? Color.secondary.opacity(0.5) : .primary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: - Words

    /// One sentence per state, saying what it means for *you* rather than what it
    /// means for the process: "an answer you have not read", not "the Stop hook
    /// fired without a pending permission".
    private static func meaning(of status: SessionStatus) -> String {
        switch status {
        case .ready:
            return "There is an answer here you have not read. Clicking the row consumes it."
        case .awaiting:
            return "Claude is blocked on a decision of yours: a permission, or a dialog. This one blinks, and it is the only one that does."
        case .working:
            return "Thinking, or running a tool. The time on the right is how long it has been at it."
        case .waiting:
            return "The turn is over and nothing needs you: background work is still registered and will wake the session when it lands."
        case .idle:
            return "At rest. Nothing to read, nothing to answer."
        case .failed:
            return "The turn ended without an answer: interrupted, or it hit an error. The right-hand cell says which."
        }
    }

    /// A reading that exists only to be drawn: the legend needs a ring that is
    /// obviously a ring, and taking one from a live row would make the picture
    /// change under the words explaining it.
    private static let sample = ContextReading(
        tokens: 640_000, model: "claude-opus-5", window: 1_000_000, confidence: .exact, at: nil
    )

    private static let provenance = """
        The figure is the tokens of the last reply (what was sent, what was \
        written into the cache and what was read back out of it) over the whole \
        context window of that model. Nothing added since that reply is in it, \
        which is why a reading that has been overtaken shows a ≥ and one whose \
        session has been compacted shows nothing at all.
        """
}

extension SessionStatus {
    /// The order the legend lists them in: what needs you, then what is busy,
    /// then what is quiet. Not the urgency ranking used for sorting the column —
    /// this one is read top to bottom once, and it groups by what you would do.
    static let legendOrder: [SessionStatus] = [
        .ready, .awaiting, .working, .waiting, .idle, .failed,
    ]
}
