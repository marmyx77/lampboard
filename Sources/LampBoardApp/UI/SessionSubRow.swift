import LampBoardCore
import SwiftUI

/// One conversation inside an opened block.
///
/// It shares three cells with the row above it so the panel keeps one vertical
/// rhythm: the dot sits inside the parent's dot column, the ring occupies the
/// parent's ring cell, and the name starts exactly where the parent's name
/// starts, with the same width. There is no indentation at all, and that is the
/// point: on a 240 point panel ten points of indent is a tenth of the field that
/// carries the identity. What gives the block its shape is the spine, drawn three
/// points inside the margin, where it costs nobody anything.
///
/// It draws less than a row on purpose. No slot, because a slot addresses a
/// project and conversations come and go. No glow and no blink: the parent
/// already blinks whenever a conversation inside it is waiting for an answer,
/// and three amber dots pulsing a centimetre apart is the Christmas tree the dot
/// was written to avoid.
struct SessionSubRow: View {
    let member: RowSession
    @Environment(\.hubSelection) private var hubSelection
    let now: Date
    let open: (RowSession) -> Void
    let rename: (RowSession) -> Void
    let dismiss: (RowSession) -> Void
    let terminate: (RowSession) -> Void
    let move: (RowSession, Int) -> Void
    /// What the block tells this line about the drag in progress. `nil` in the
    /// narrow panel, where there is no handle and nothing to drag.
    var drag: RowDragState? = nil

    @State private var hovering = false

    private var session: SessionState { member.session }

    /// The conversation as a row of its own, which is what the card knows how to
    /// read. Without it the only second layer in an opened project would be the
    /// parent's, and the parent's card can only speak for the project.
    private var card: ColumnRow {
        ColumnRow(id: member.id, workspace: session.workspace, sessions: [session], alias: member.name)
    }

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: Layout.dotToRing) {
                // The same size as the row above it. A smaller one read as an
                // inconsistency rather than as a hierarchy, and it made the mark
                // the app exists for the weakest thing on the line. What separates
                // a conversation from its project is the well, the type and the
                // dimmer name.
                TrafficLightDot(status: session.status, calm: true, listening: false)

                ContextRing(reading: session.context)
            }

            Text(member.name)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(Color.primary.opacity(session.status == .idle ? 0.55 : 0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            // Where it is actually true. On the parent this number is a sum
            // across the whole project, so three subagents in one conversation
            // and one each in three read the same; here it belongs to the line
            // that owns it.
            if session.activeSubagents > 0 {
                Text("×\(session.activeSubagents)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(StatusPalette.badgeForeground)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(StatusPalette.badgeBackground))
                    .fixedSize()
            }

            Spacer(minLength: 4)

            Text(timeLabel)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(StatusPalette.timeColor)
                .lineLimit(1)
                .layoutPriority(1)
                .monospacedDigit()

            // A grip that is drawn has to work. Leaving it inert while the menu
            // did the moving was a promise the panel did not keep, and the model
            // it broke is the obvious one: the handle on the heading moves the
            // block, the handle on a line moves the line.
            if let drag {
                ZStack {
                    DragHandle(onChanged: drag.onChanged, onEnded: drag.onEnded)
                    AgentGrip(harness: session.harness).allowsHitTesting(false)
                }
                .frame(width: 14, height: Layout.subRowHeight)
            } else {
                AgentGrip(harness: session.harness)
            }
        }
        .offset(y: drag?.offset ?? 0)
        .zIndex(drag?.isDragged == true ? 1 : 0)
        .padding(.horizontal, 6)
        .frame(height: Layout.subRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(drag?.isDragged == true ? 0.16 : hovering ? 0.10 : hubSelection == member.id ? 0.14 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open(member) }
        .tooltip(RowSummary.of(card, now: now, revealable: false))
        .contextMenu {
            Button("Open this conversation") { open(member) }
            Divider()
            Button("Move up") { move(member, -1) }
            Button("Move down") { move(member, 1) }
            Divider()
            Button("Rename this conversation\u{2026}") { rename(member) }
            Divider()
            Button("Remove this row") { dismiss(member) }
            Button("End this session\u{2026}") { terminate(member) }
        }
    }

    /// The same rule the row uses: how long while it is going, why it stopped
    /// when it failed, and when otherwise.
    private var timeLabel: String {
        switch session.status {
        case .working, .waiting:
            return CompactDuration.label(seconds: session.statusDuration(at: now))
        case .failed:
            return (session.failureReason ?? .unknown).shortLabel
        case .idle, .awaiting, .ready:
            return RelativeTime.label(for: session.updatedAt, now: now)
        }
    }
}

/// The grip you drag a line by, tinted with the agent that owns it.
///
/// Six dots in two columns rather than three lines. Three horizontal lines are
/// also what a menu looks like, and this one is only ever a handle; a grip of
/// dots is the mark half the system uses for a sortable list and says nothing
/// else. It is also drawn brighter than the old one: the comment above the
/// handle said a mark you have to hover to find is a mark nobody finds, and then
/// drew it at 30 percent.
///
/// The colour is the last free space on the row, and it is far from the dot: the
/// grip sits in the last cell, two hundred points away, and every line has one.
/// A tint that is always there reads as a label, not as an alarm.
struct AgentGrip: View {
    /// `nil` is the project's own grip, which belongs to no agent.
    let harness: Harness?
    var bright: Bool = false
    var height: CGFloat = Layout.subRowHeight

    var body: some View {
        Group {
            if harness == nil {
                // Six dots in two columns for the project. Three horizontal lines
                // are also what a menu looks like, and this one is only ever a
                // handle; a grip of dots is the mark half the system uses for a
                // sortable list and says nothing else.
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 3) { dot; dot }
                    }
                }
            } else {
                // Three lines for a conversation, and the difference is the point:
                // two handles sit a few points apart and each moves a different
                // thing. Same shape twice would have been the panel asking you to
                // remember which row you were on.
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in bar }
                }
            }
        }
        .frame(width: 14, height: height)
    }

    /// Whole points, and one implementation for both places. The first version
    /// drew 2.5 point dots on the row and 2 point dots on the conversations,
    /// which is two mistakes at once: the two grips did not match, and a 2.5
    /// point circle lands on half a device pixel, so the same dot rendered
    /// heavier or lighter depending on where its row fell. Reported as "they look
    /// like different sizes", which is exactly what was happening.
    private var dot: some View {
        Circle().fill(tint).frame(width: 2, height: 2)
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
            .fill(tint)
            .frame(width: 9, height: 1)
    }

    private var tint: Color {
        guard let harness else { return StatusPalette.neutralGrip.opacity(bright ? 1 : 0.72) }
        return StatusPalette.agentTint(for: harness)
    }
}
