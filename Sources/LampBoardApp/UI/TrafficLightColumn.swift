import Combine
import LampBoardCore
import SwiftUI

/// The column of traffic lights: one row per project, or per session when
/// grouping is off.
struct TrafficLightColumn: View {
    @ObservedObject var store: StateStore
    /// In the Hub the rows take the sidebar's width; in the panel, the panel's (D150).
    @Environment(\.columnFillsWidth) private var fillsWidth
    let compact: Bool
    let options: ColumnOptions
    let notificationsEnabled: Bool
    let mutedWorkspaces: Set<String>
    let calmWorkspaces: Set<String>
    var focusedSession: String? = nil
    let actions: RowActions
    /// The projects whose conversations are shown under them.
    let expandedRows: Set<String>
    let onRevealHidden: () -> Void
    /// Files two live sessions both wrote lately, by session (R3a).
    var conflicts: [String: [FileConflicts.Conflict]] = [:]
    /// The sample rows, added to what the column draws and to nothing else (U4).
    @ObservedObject var samples: SampleStage
    /// Whether Claude Code is connected, and how to connect it, for the empty
    /// column's guidance (U4).
    var connected = true
    var connect: () -> Void = {}
    /// What waits, for the asks drawn under their rows and the row J and K are
    /// on (U2); nil in the narrow panel.
    var queue: WaitingQueueModel? = nil
    /// Opens or closes the «Resting» line (U2).
    var toggleResting: () -> Void = {}

    /// Reference moment for the time labels.
    ///
    /// A reference that advances on its own is needed: session state doesn't
    /// change at midnight, but the label does — a "23:50" has to become
    /// "yesterday" without waiting for the next hook signal.
    @State private var now = Date()

    /// One minute is the longest step that guarantees the label changes within a
    /// minute of the day rolling over.
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The drag in progress: which row, and how far the handle has travelled.
    ///
    /// Only the id is kept, not the row's index. Rows can appear or leave while
    /// the pointer is down — a session ends, a project is seen for the first time
    /// — and an index remembered at mouse-down would then point at the wrong row.
    /// The index is looked up on every render instead.
    @State private var drag: ColumnDrag?

    private struct ColumnDrag: Equatable {
        let rowId: String
        var translation: CGFloat
    }

    /// The drag inside an opened block: which project, which conversation, how
    /// far. Separate from the column's own, because the two handles are on
    /// different lines and must never be able to interfere.
    @State private var memberDrag: MemberDrag?

    private struct MemberDrag: Equatable {
        let rowId: String
        let memberId: String
        var translation: CGFloat
    }

    /// Inside a block every line is the same height, so one pitch is enough here,
    /// unlike the column outside where an opened project is as tall as what it
    /// shows.
    private static let memberPitch = Layout.subRowHeight + Layout.rowSpacing

    /// With the clock, so rows at rest for half a day fold (U2). The wall clock
    /// and not `now`, which ticks once a minute: the window is sized from the
    /// same call (`PanelController.resizeToFit`), and the two must agree.
    private var rendering: ColumnRendering {
        ColumnLayout.render(store.state.adding(samples.sessions()), options: options, now: Date())
    }

    var body: some View {
        let rendering = self.rendering

        return Group {
            if rendering.rows.isEmpty && rendering.hidden == nil && rendering.resting == nil {
                emptyState(filteredOut: rendering.filteredOut)
            } else {
                content(rendering)
            }
        }
        .padding(Layout.panelPadding)
        .frame(width: fillsWidth ? nil : Layout.width(compact: compact))
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .onReceive(tick) { now = $0 }
        // A card describes the row that was under the pointer. When rows
        // reorder, arrive or leave, another one may be there now and the card
        // would describe the wrong session (U1).
        .onChange(of: rendering.rows.map(\.id)) { Tooltip.hide() }
    }

    // MARK: - Rows

    private func content(_ rendering: ColumnRendering) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Layout.rowSpacing) {
                ForEach(Array(rendering.rows.enumerated()), id: \.element.id) { index, row in
                    block(row, at: index, in: rendering.rows)
                }

                if let resting = rendering.resting {
                    RestingRow(summary: resting, compact: compact, toggle: toggleResting)
                    if resting.isOpen {
                        ForEach(resting.rows) { row in
                            TrafficLightRow(row: row, compact: compact, now: now,
                                            flags: flags(for: row, expanded: false, singleLine: true), actions: actions)
                        }
                    }
                }

                if let hidden = rendering.hidden {
                    HiddenSummaryRow(
                        summary: hidden,
                        compact: compact,
                        onReveal: onRevealHidden
                    )
                }

                if rendering.filteredOut > 0 {
                    filterNote(count: rendering.filteredOut)
                }
            }
        }
        // Scrolls only when the content genuinely does not fit the screen. The
        // old rule was a count of rows, which stopped being the same question the
        // moment a project could open.
        .scrollDisabled(false)
    }

    // MARK: - The block

    /// A project, and its conversations when it is open.
    ///
    /// The fill and the hairline are there whenever the project holds more than
    /// one conversation, open or not, and that is the sign that it opens: a
    /// project with a single session has no block, so it cannot pretend to have
    /// one. A leading chevron would have charged **every** name in the column 13
    /// points on a 240 point panel, for a minority of rows.
    @ViewBuilder
    private func block(_ row: ColumnRow, at index: Int, in rows: [ColumnRow]) -> some View {
        let holdsMany = row.count > 1
        let open = holdsMany && expandedRows.contains(row.id)
        let drag = dragState(for: row, at: index, in: rows)

        if compact {
            narrowBlock(row, at: index, in: rows, holdsMany: holdsMany, open: open)
        } else {
            VStack(spacing: Layout.rowSpacing) {
                // The row and the ask it holds are one piece: no gap between them.
                VStack(spacing: 0) {
                    TrafficLightRow(
                        row: row,
                        compact: false,
                        now: now,
                        flags: flags(for: row, expanded: open),
                        actions: actions,
                        drag: drag
                    )
                    if let queue { InlineAskView(queue: queue, sessionIds: row.sessions.map(\.id)) }
                }
                .overlay {
                    if let queue { SelectionRing(queue: queue, sessionIds: Set(row.sessions.map(\.id))) }
                }

                if open { conversations(of: row) }
            }
            // Vertical only. Padding the sides too moved the dot of every row
            // inside a block three points right, and the column of dots is the
            // thing you scan: one crooked row in twelve is read as the panel being
            // broken. The fill runs the full width instead, which loses nothing,
            // because what makes the block a block is the fill and the spine and
            // not an indent.
            .padding(.vertical, holdsMany ? Layout.blockInset : 0)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(holdsMany ? StatusPalette.blockWell : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(holdsMany ? StatusPalette.blockEdge : Color.clear, lineWidth: 1)
                    )
            )
            // The whole block follows the pointer, and steps aside — animated —
            // when another block is dragged past it. On the block and not on the
            // row that carries the handle: a project that is open **is** its
            // header, its conversations and the well around them, and moving one
            // third of that was the defect. Closed, the two are the same thing,
            // which is why it only ever looked wrong open.
            .offset(y: drag.offset)
            .zIndex(drag.isDragged ? 1 : 0)
            .shadow(color: .black.opacity(drag.isDragged ? 0.35 : 0), radius: drag.isDragged ? 6 : 0, y: 2)
            .animation(drag.isDragged ? nil : .easeOut(duration: 0.12), value: drag.offset)
        }
    }

    /// The same block at 35 points, where there is no name, no count and no
    /// chevron, and a project holding three conversations is otherwise the **same
    /// pixel** as one holding a single session.
    ///
    /// One mark does both jobs. Whole, it runs down the side of the group and says
    /// these belong together; folded to a stub, it says there is more than one in
    /// here. The same sign twice rather than a second thing to learn.
    ///
    /// Drawn inside the panel's own padding, because 35 points leaves 19 of
    /// content and the dot takes 13: there is no room beside it. Putting the line
    /// in the margin is what keeps the dots in one column, and a grouped row
    /// aligned with one that is not.
    private func narrowBlock(
        _ row: ColumnRow, at index: Int, in rows: [ColumnRow], holdsMany: Bool, open: Bool
    ) -> some View {
        VStack(spacing: Layout.rowSpacing) {
            TrafficLightRow(
                row: row,
                compact: true,
                now: now,
                flags: flags(for: row, expanded: open),
                actions: actions,
                drag: nil
            )

            if open {
                ForEach(row.members.prefix(Layout.subRowCap)) { member in
                    TrafficLightDot(status: member.session.status, calm: true, listening: false)
                        .scaleEffect(Layout.compactSubDotSize / Layout.dotSize)
                        .frame(maxWidth: .infinity)
                        .frame(height: Layout.subRowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.openSession(member) }
                        .tooltip(RowSummary.of(
                            ColumnRow(
                                id: member.id,
                                workspace: row.workspace,
                                sessions: [member.session],
                                alias: member.name
                            ),
                            now: now,
                            revealable: false
                        ))
                }
            }
        }
        .overlay(alignment: .leading) {
            if holdsMany {
                // At the very left of the content, not in the panel's padding: the
                // scrolling view clips to its own bounds, so a line drawn outside
                // them is drawn and never seen. Thirty-five points leave nineteen
                // of content and the dot takes thirteen, which leaves three on
                // each side, and this needs two of them.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.primary.opacity(0.38))
                    .frame(width: 2, height: open ? nil : 11)
                    .padding(.vertical, open ? 2 : 0)
            }
        }
    }

    /// The conversations under an opened project.
    ///
    /// There used to be a spine down their left as well, and it went when the
    /// panel got its own dark floor: the well already says these belong together,
    /// and a second mark saying the same thing is what made the column feel busy.
    /// It survives in the narrow panel, where there is no well for it to repeat.
    ///
    /// Capped, because twelve of them is 264 points of panel for one project and
    /// a column that scrolls is a column where the row that needs you can be off
    /// screen. The tail says how many were left rather than leaving you to count.
    private func conversations(of row: ColumnRow) -> some View {
        let shown = Array(row.members.prefix(Layout.subRowCap))
        let rest = row.members.count - shown.count

        return VStack(spacing: Layout.rowSpacing) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, member in
                SessionSubRow(
                    member: member,
                    now: now,
                    open: actions.openSession,
                    rename: actions.renameSession,
                    dismiss: actions.dismissSession,
                    terminate: actions.terminateSession,
                    move: { member, offset in actions.moveSession(row, member, offset) },
                    drag: compact ? nil : memberDragState(
                        for: member, at: index, in: shown, of: row
                    )
                )
            }

            if rest > 0 {
                Text("and \(rest) more")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Layout.tailHeight - Layout.rowSpacing)
                    .padding(.leading, 6)
            }
        }
    }

    /// What one conversation draws during a drag inside its block, and how it
    /// reports one of its own.
    ///
    /// The same shape as the column's, one level down and simpler: the lines are
    /// all the same height, so the gap travels by whole pitches. The drop is
    /// applied as a **move by an offset**, which is what the menu entry already
    /// did, so both gestures end in one place and neither can invent an order the
    /// other cannot express.
    private func memberDragState(
        for member: RowSession, at index: Int, in shown: [RowSession], of row: ColumnRow
    ) -> RowDragState {
        var offset: CGFloat = 0
        var dragged = false

        if let memberDrag, memberDrag.rowId == row.id,
           let start = shown.firstIndex(where: { $0.id == memberDrag.memberId }) {
            let steps = Int((memberDrag.translation / Self.memberPitch).rounded())
            let end = min(max(start + steps, 0), shown.count - 1)

            if memberDrag.memberId == member.id {
                dragged = true
                let lowest = -CGFloat(start) * Self.memberPitch
                let highest = CGFloat(shown.count - 1 - start) * Self.memberPitch
                offset = min(max(memberDrag.translation, lowest), highest)
            } else if start < end, index > start, index <= end {
                offset = -Self.memberPitch
            } else if start > end, index >= end, index < start {
                offset = Self.memberPitch
            }
        }

        return RowDragState(
            offset: offset,
            isDragged: dragged,
            onChanged: { translation in
                if memberDrag == nil {
                    memberDrag = MemberDrag(
                        rowId: row.id, memberId: member.id, translation: translation
                    )
                } else if memberDrag?.memberId == member.id {
                    memberDrag?.translation = translation
                }
            },
            onEnded: {
                guard let current = memberDrag, current.memberId == member.id else { return }
                memberDrag = nil
                guard let start = shown.firstIndex(where: { $0.id == current.memberId }) else { return }
                let steps = Int((current.translation / Self.memberPitch).rounded())
                let end = min(max(start + steps, 0), shown.count - 1)
                guard end != start else { return }
                actions.moveSession(row, member, end - start)
            }
        )
    }

    /// How tall each row draws. The same function the panel sizes itself with, so
    /// a drop cannot land somewhere the window does not think exists.
    private func heights(of rows: [ColumnRow]) -> [CGFloat] {
        rows.map { row in
            let open = row.count > 1 && expandedRows.contains(row.id)
            let shown = open ? min(row.members.count, Layout.subRowCap) : 0
            return Layout.blockHeight(
                rowCount: row.count,
                shownConversations: shown,
                hasTail: open && row.members.count > shown,
                compact: compact,
                asks: row.sessions.contains { queue?.inlineSessions.contains($0.id) == true }
            )
        }
    }

    // MARK: - Reordering

    /// Where the dragged row would land if released now.
    ///
    /// By **centres** rather than by a fixed pitch, because a row is no longer one
    /// height: an opened project is as tall as the conversations it is showing.
    /// Counting steps of a constant pitch would put the drop one or two rows off
    /// as soon as anything above it was open, and a drop that lands somewhere else
    /// is the worst possible outcome for a gesture whose whole content is where it
    /// lands.
    private func target(of drag: ColumnDrag, in rows: [ColumnRow]) -> (start: Int, end: Int)? {
        guard let start = rows.firstIndex(where: { $0.id == drag.rowId }) else { return nil }
        let centres = self.centres(of: rows)
        let wanted = centres[start] + drag.translation
        let end = centres.enumerated()
            .min { abs($0.element - wanted) < abs($1.element - wanted) }?.offset ?? start
        return (start, end)
    }

    /// The vertical middle of each row, measured from the top of the column.
    private func centres(of rows: [ColumnRow]) -> [CGFloat] {
        var result: [CGFloat] = []
        var top: CGFloat = 0
        for height in heights(of: rows) {
            result.append(top + height / 2)
            top += height + Layout.rowSpacing
        }
        return result
    }

    /// What this row draws during a drag, and how it reports one of its own.
    ///
    /// The dragged row follows the pointer, clamped to the column. Every row
    /// between its origin and its destination steps one pitch aside, so the gap
    /// travels with the pointer and the drop lands where the eye expects.
    private func dragState(for row: ColumnRow, at index: Int, in rows: [ColumnRow]) -> RowDragState {
        var offset: CGFloat = 0
        var dragged = false
        if let drag, let (start, end) = target(of: drag, in: rows) {
            let centres = self.centres(of: rows)
            let step = heights(of: rows)[start] + Layout.rowSpacing
            if drag.rowId == row.id {
                dragged = true
                let lowest = centres.first.map { $0 - centres[start] } ?? 0
                let highest = centres.last.map { $0 - centres[start] } ?? 0
                offset = min(max(drag.translation, lowest), highest)
            } else if start < end, index > start, index <= end {
                offset = -step
            } else if start > end, index >= end, index < start {
                offset = step
            }
        }
        return RowDragState(
            offset: offset,
            isDragged: dragged,
            onChanged: { translation in
                if drag == nil {
                    drag = ColumnDrag(rowId: row.id, translation: translation)
                } else if drag?.rowId == row.id {
                    drag?.translation = translation
                }
            },
            onEnded: {
                guard let current = drag, current.rowId == row.id else { return }
                drag = nil
                guard let (start, end) = target(of: current, in: rows), start != end else { return }
                actions.place(row, end)
            }
        )
    }

    private func flags(for row: ColumnRow, expanded: Bool, singleLine: Bool = false) -> RowFlags {
        RowFlags(
            isHidden: options.hidden.contains(row.workspace.key),
            isMuted: mutedWorkspaces.contains(row.workspace.key),
            isCalm: calmWorkspaces.contains(row.workspace.key),
            notificationsEnabled: notificationsEnabled,
            isExpanded: expanded,
            conflict: conflictLine(for: row),
            isFocused: focusedSession.map { id in row.sessions.contains { $0.id == id } } ?? false,
            modInUse: store.state.sessions.values.contains { $0.context?.confidence == .reported },
            singleLine: singleLine
        )
    }

    /// "Also wrote routes.ts: api-gateway", for the row's sessions, or `nil`.
    private func conflictLine(for row: ColumnRow) -> String? {
        let mine = Set(row.sessions.map(\.id))
        let shared = row.sessions.flatMap { conflicts[$0.id] ?? [] }.filter { !mine.contains($0.with) }
        guard !shared.isEmpty else { return nil }
        let lines = Dictionary(grouping: shared, by: \.file).sorted { $0.key < $1.key }.map { file, found in
            let others = Set(found.map(\.with)).sorted().map { id in
                store.state.sessions[id].map { RowActivity.flat($0.displayName) } ?? String(id.prefix(8))
            }
            return "\((file as NSString).lastPathComponent) also written by " + others.joined(separator: ", ")
        }
        return "Two sessions on the same file: " + lines.joined(separator: "; ")
    }

    /// How many sessions the filter is keeping out.
    ///
    /// Without this row the filter would lie by omission: a column with two rows
    /// would look like it says "there are two sessions", when what it says is
    /// "two need attention".
    private func filterNote(count: Int) -> some View {
        HStack(spacing: 7) {
            if compact {
                Text("\(count)")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                    .frame(maxWidth: .infinity)
            } else {
                Text("and \(count) more with nothing new")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                    .lineLimit(1)
            }
        }
        .frame(height: Layout.rowHeight * 0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .tooltip("The “only what's waiting” filter is hiding \(count) sessions that are idle or working.")
    }

    /// Nothing to show. In the wide panel it says what to do (U4): connect
    /// Claude Code when nothing is connected — the 1.0 panel said only «waiting
    /// for sessions», and that usually meant «not connected» —, otherwise start a
    /// session, or put three sample rows in. Its height is `Layout.emptyGuidance`,
    /// which the window counts.
    @ViewBuilder
    private func emptyState(filteredOut: Int) -> some View {
        if compact || filteredOut > 0 {
            HStack(spacing: 7) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: Layout.dotSize, height: Layout.dotSize)
                if !compact {
                    Text("none waiting")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .frame(height: Layout.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .tooltip(filteredOut > 0
                     ? "The “only what's waiting” filter is on and \(filteredOut) sessions are asking for nothing."
                     : "No sessions yet. Widen the panel to see what to do.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(connected ? "Connected." : "No lamps yet.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(connected
                     ? "Start or restart a Claude Code session: its lamp appears here."
                     : "Connect Claude Code, so each session can tell the panel what it is doing.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(connected ? "No session at hand? Practice with samples" : "Connect Claude Code") {
                    if connected { samples.start() } else { connect() }
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .frame(height: Layout.emptyGuidance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The row summarizing the projects that were set aside.
///
/// **It lights up** when a hidden session asks for attention. That is not an
/// aesthetic detail: without it, "hide" would become "forget", which is exactly
/// the harm this panel exists to prevent.
private struct HiddenSummaryRow: View {
    let summary: HiddenSummary
    let compact: Bool
    let onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if summary.needsAttention {
                TrafficLightDot(status: summary.status)
            } else {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                    .frame(width: Layout.dotSize, height: Layout.dotSize)
            }

            if !compact {
                Text("\(summary.sessionCount) hidden")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Layout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onReveal)
        .tooltip(tooltip)
    }

    private var tooltip: String {
        var lines = ["Hidden projects: \(summary.workspaceNames.joined(separator: ", "))"]
        if summary.needsAttention {
            lines.append("One of them: \(summary.status.label).")
        }
        lines.append("Click to bring them all back into the column.")
        return lines.joined(separator: "\n")
    }
}

/// The line the rows at rest for half a day fold into (U2): a grey ring, then
/// «Resting · 3 — legacy-import, billing-worker, checkout-api». A click opens it.
private struct RestingRow: View {
    let summary: RestingSummary
    let compact: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            TrafficLightDot(status: .idle)
            if !compact {
                Image(systemName: summary.isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StatusPalette.timeColor)
                Text(summary.line)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Layout.rowHeight)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .tooltip(summary.line + ". At rest for twelve hours or more. Click to " + (summary.isOpen ? "fold them." : "list them."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.line)
        .accessibilityValue(summary.isOpen ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
    }
}

/// The ring around the row J and K are on, while the panel has the keys (U2).
private struct SelectionRing: View {
    @ObservedObject var queue: WaitingQueueModel
    let sessionIds: Set<String>

    var body: some View {
        if !queue.selectedSessions.isDisjoint(with: sessionIds) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(StatusPalette.color(for: .awaiting).opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// Whether the column takes the width it is given rather than the panel's own:
/// on only in the Hub's sidebar (D150).
private struct ColumnFillsWidthKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var columnFillsWidth: Bool {
        get { self[ColumnFillsWidthKey.self] }
        set { self[ColumnFillsWidthKey.self] = newValue }
    }
}
