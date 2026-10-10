import LampBoardCore
import SwiftUI

/// The actions a row's context menu can perform.
///
/// They are gathered into a type rather than passed one by one because there are
/// six of them and there will be more: a signature with six closures becomes
/// unreadable the first time a parameter is added in the middle.
struct RowActions {
    var open: (ColumnRow) -> Void
    let peek: (ColumnRow) -> Void
    let markUnread: (ColumnRow) -> Void
    /// Moves the row one place up (`-1`) or down (`+1`) among the rows shown.
    let move: (ColumnRow, Int) -> Void
    /// Puts the row at a position among the rows shown; what a drag ends with.
    let place: (ColumnRow, Int) -> Void
    let toggleHidden: (ColumnRow) -> Void
    let toggleMuted: (ColumnRow) -> Void
    let toggleCalmBlink: (ColumnRow) -> Void
    let newConversation: (ColumnRow) -> Void
    /// Opens the conversation in a window of its own, without touching VS Code.
    let openChat: (ColumnRow) -> Void
    /// Gives the row the name the user wants to read, by folder.
    let rename: (ColumnRow) -> Void
    /// Opens or closes the block: what a click on a project holding several
    /// conversations does, since a row that contains rows is a heading.
    let toggleExpansion: (ColumnRow) -> Void
    /// Raises one conversation, and clears only that one.
    var openSession: (RowSession) -> Void
    /// Names one conversation, touching nothing else.
    let renameSession: (RowSession) -> Void
    let dismissSession: (RowSession) -> Void
    let terminateSession: (RowSession) -> Void
    /// Names this agent's lane in this project, which every conversation of that
    /// agent falls back to.
    /// Moves one conversation up (`-1`) or down (`+1`) inside its project.
    let moveSession: (ColumnRow, RowSession, Int) -> Void
    /// Opens the folder the session is working in, in the Finder.
    let revealInFinder: (ColumnRow) -> Void
    /// Opens the row's session in the Plancia, beside the list (D79).
    var openPlancia: (ColumnRow) -> Void = { _ in }
    /// The decision board of the row's repository (D105): pin one, take one off
    /// by its number, and the ones pinned now, for the menu.
    var pinDecision: (String) -> Void = { _ in }
    var unpinDecision: (String, Int) -> Void = { _, _ in }
    var decisions: (String) -> [String] = { _ in [] }
    /// The governor's offer for the row, and taking it or giving it back (G3).
    var governorOffer: (ColumnRow) -> GovernorOffer? = { _ in nil }
    var toggleModel: (ColumnRow) -> Void = { _ in }
    /// Puts the row's session in the foreground, or takes it out (G1).
    var toggleFocus: (ColumnRow) -> Void = { _ in }
    /// What the live view could open for a session, if anything (D130, D132).
    var liveTarget: (SessionState) -> LiveTarget? = { _ in nil }
    /// Opens it in the live view, and starts a new session there (D130).
    var openHere: (LiveTarget) -> Void = { _ in }
    var startHere: (ColumnRow) -> Void = { _ in }
    /// A conversation in VS Code, moved to the live view (D135).
    var canMoveHere: (SessionState) -> Bool = { _ in false }
    var moveHere: (ColumnRow) -> Void = { _ in }
    /// Copies the command that opens it in a terminal of one's own (AV2).
    var copyCommand: (String) -> Void = { _ in }
    /// Takes the sample rows away (U4).
    var removeSamples: () -> Void = {}
}

/// What the column tells a row about the drag in progress.
///
/// The drag is the column's business — it is the column that knows how many
/// rows there are and which one the pointer is over — so the row only draws
/// where it is told to and reports the handle's movement back.
struct RowDragState {
    /// Vertical displacement to draw the row at, in points.
    let offset: CGFloat
    /// `true` for the row under the pointer.
    let isDragged: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
}

/// State of the preferences that concern one row.
struct RowFlags {
    let isHidden: Bool
    let isMuted: Bool
    let isCalm: Bool
    let notificationsEnabled: Bool
    /// `true` while this project's conversations are shown under it.
    let isExpanded: Bool
    /// Another live session wrote a file this one wrote (UX §4, R3a): what to say
    /// in the ⚠'s tooltip, or `nil`.
    var conflict: String? = nil
    /// The row holds the session in the foreground (G1).
    var isFocused = false
    /// Some session's mod is heard from, so a silent one can be drawn hollow (R4).
    var modInUse = false
    /// One line even in the wide panel: a row listed under «Resting» (U2), whose
    /// second line had nothing to say but the name of its agent.
    var singleLine = false
}

/// One row of the column: a light and, in expanded mode, the project name with
/// the time of the last activity.
struct TrafficLightRow: View {
    let row: ColumnRow
    let compact: Bool
    /// Reference moment for the time label, updated by the column.
    let now: Date
    let flags: RowFlags
    let actions: RowActions
    /// `nil` in compact mode, where there is no room for a handle.
    var drag: RowDragState? = nil

    @State private var hovering = false
    /// The conversation open in the Hub, marked like a hover (D150).
    @Environment(\.hubSelection) private var hubSelection
    private var isOpenInHub: Bool { row.count == 1 && hubSelection == row.primary.id }
    @State private var hoveringFolder = false

    private var isDragged: Bool { drag?.isDragged ?? false }

    private var activity: String { RowActivity.line(for: row, now: now) }

    /// The row's own height: the folder, the grip and the handle are as tall as
    /// it, or a third of a wide row is a place the pointer cannot grab.
    private var height: CGFloat { compact || flags.singleLine ? Layout.rowHeight : Layout.wideRowHeight }

    private var accessibilitySentence: String {
        var parts = [row.displayName, row.status.label, activity]
        if row.count > 1 { parts.insert("\(row.count) conversations", at: 1) }
        if let context = row.context { parts.append("context " + context.label) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 7) {
            // The light and its ring travel together, closer to each other than
            // to anything else: same session, two questions.
            HStack(spacing: Layout.dotToRing) {
                TrafficLightDot(status: row.status, calm: flags.isCalm, listening: row.listeners > 0,
                                style: row.lampStyle(now: now, modInUse: flags.modInUse))

                if !compact {
                    ring
                }
            }

            if !compact {
                place

                // Two lines in the wide panel (D76): the name and its time, and
                // under them what the session is doing now — the phrase the card
                // would take a hover to say.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text(row.displayName)
                            // Twelve points, not eleven. The point came out of the
                            // timestamp: `yesterday` was 49.83 points of a field this one
                            // shares, `1d` is 13.04, and the tooltip says the word. Even
                            // on the rows that kept the widest label — `14:56`, `22/07` —
                            // the name loses two points and gains a size.
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(labelColor)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        recall

                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(StatusPalette.badgeForeground)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(StatusPalette.badgeBackground)
                                )
                                .fixedSize()
                        }

                        blockBadge

                        // The prompt cache's minutes while the session waits for you
                        // (R3b): answered now, it reads the conversation back cheaply.
                        if row.status.isWaitingOnPerson, let minutes = CacheClock.minutesLeft(row.context, now: now) {
                            Text("⟳\(minutes)m")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(StatusPalette.timeColor)
                                .tooltip("The prompt cache stays warm \(minutes) more minutes: an answer now rereads this conversation cheaply")
                                .fixedSize()
                        }

                        if let conflict = flags.conflict {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(StatusPalette.color(for: .failed))
                                .tooltip(conflict)
                                .accessibilityLabel(conflict)
                        }

                        if flags.isFocused {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(StatusPalette.lampMasterTint)
                                .tooltip("In focus: the other sessions' notifications wait until you take it off")
                                .accessibilityLabel("in focus")
                        }

                        // Answers nobody has read, from two on (R3c).
                        if let unread = row.unreadBadge {
                            Text(unread)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(StatusPalette.lampMasterTint)
                                .tooltip("\(unread.dropFirst()) answers since you last looked")
                                .accessibilityLabel("\(unread.dropFirst()) unread answers")
                                .fixedSize()
                        }

                        Spacer(minLength: 4)

                        Text(timeLabel)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            // The hierarchy against the name comes from the font weight,
                            // not from fading the color: on a dark vibrant surface
                            // `.tertiary` becomes illegible, and a timestamp you can't
                            // read takes up space without saying anything.
                            .foregroundStyle(StatusPalette.timeColor)
                            .lineLimit(1)
                            // Stops a long name from squeezing out the timestamp: the
                            // timestamp has priority, it's the information read in passing.
                            .layoutPriority(1)
                            .monospacedDigit()
                    }
                    if !flags.singleLine {
                        Text(activity)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(StatusPalette.timeColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                // Appears under the pointer and takes eighteen points off the
                // name while it is there. That cost is the whole argument: the
                // alternative was carrying it on every row for ever, on rows
                // where it cannot even work — a session on another machine has a
                // path, and it is not a path on this Mac.
                if hovering, !row.workspace.isRemote, !isSample {
                    folderButton
                }

                if let drag, !isSample {
                    handle(drag)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .padding(.horizontal, 6)
        .frame(height: height)
        // Compact mode is thirty-five points of panel with one eleven-point dot
        // in it: leading alignment left that dot two points off the centre line,
        // which on a column of twelve rows reads as a column that is crooked.
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isDragged ? 0.18 : hovering ? 0.12 : isOpenInHub ? 0.14 : 0))
        )
        .contentShape(Rectangle())
        // One sentence for VoiceOver, the way the UX spells it: the project,
        // its state, what it is doing, its context. The parts are drawn as a
        // light, a ring and two lines, none of which a screen reader can see.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySentence)
        .accessibilityValue(row.count > 1 ? (flags.isExpanded ? "expanded" : "collapsed") : "")
        .accessibilityAddTraits(.isButton)
        // The children are folded into one sentence, so what they do is offered
        // here: a screen reader cannot hover for the folder or drag the handle.
        .accessibilityAction(named: "Open") { actions.open(row) }
        .accessibilityAction(named: "Move up") { actions.move(row, -1) }
        .accessibilityAction(named: "Move down") { actions.move(row, 1) }
        .accessibilityAction(named: "Show in Finder") { actions.revealInFinder(row) }
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
        .contextMenu { menu }
        .tooltip(RowSummary.of(row, now: now, muted: flags.isMuted))
        // The movement is **not** here. A row is the top line of a project, and a
        // project that is open owns the conversations under it and the well
        // around them: a header that followed the pointer on its own slid
        // straight through its own rows and left the card behind, which read as
        // the panel breaking rather than as a drag. What moves is the block, and
        // only the column knows where a block begins and ends — see
        // `TrafficLightColumn.block(_:at:in:)`.
        //
        // What stays is the handle and the light it puts in the grip: this row
        // starts the drag, it just does not draw it.
    }

    /// Where this row is, when that is not "in an editor window on this Mac".
    ///
    /// One slot and one glyph, and the remote mark takes it. The two answer the
    /// same question — what a click can reach — and if a row were ever both, the
    /// machine is the half that changes the answer: no folder here to open, no
    /// transcript here to read, which is exactly what the row's menu drops. As it
    /// stands they cannot collide, because a signal that names a host skips the
    /// unclaimed-folder branch that makes a row terminal.
    ///
    /// `R` and not the machine's name. The name was on the row until today and it
    /// was the loudest thing on it: `@devmachine` is eleven characters out of a
    /// field a project name has to fit in, identical on every row of that node,
    /// and `Acme Events @devmachine` reached the screen as `Acme …machine`. A
    /// letter says *not here* in the width of a glyph; **which** machine is a
    /// question one person asks at a time, and the card answers it in words.
    private var place: some View {
        Group {
            if row.workspace.isRemote {
                Text("R")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(StatusPalette.badgeForeground)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(StatusPalette.badgeBackground))
                    .fixedSize()
            } else if row.isTerminal {
                // Its click leads to a tab, not to an editor window.
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StatusPalette.timeColor)
            }
        }
    }

    /// How full this session's context is, and on which model.
    ///
    /// It took the cell the slot number used to have: the slot answers "which key
    /// opens this" once and never changes, and it reads well enough in the
    /// tooltip. This changes while you work, and it is what decides whether a
    /// large task starts here or in a new session.
    ///
    /// Drawn on every row, including the ones with nothing read yet — a cell that
    /// appeared and disappeared would move the names of half the column sideways
    /// every time a session replied.
    private var ring: some View {
        // A watched command has no context: the place is kept, so the names stay
        // in line, and nothing is drawn in it — a dashed ring would say "nothing
        // read yet" about something that will never have a reading.
        ContextRing(reading: row.context)
            .opacity(row.primary.harness == .command ? 0 : 1)
    }

    /// The folder this session is working in, one click away.
    ///
    /// Drawn only while the pointer is on the row. A permanent icon would be
    /// eighteen points off every name — measured: 100.87 becomes 82.87, which is
    /// where the names were before this afternoon's work gave the width back —
    /// and it would have to disappear on remote rows anyway, which is the same
    /// jump with worse timing.
    private var folderButton: some View {
        Button {
            actions.revealInFinder(row)
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(hoveringFolder ? 0.85 : 0.45))
                .frame(width: 13, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringFolder = $0 }
        .transition(.opacity)
    }

    /// The three lines on the right: where you grab the row to move it.
    ///
    /// Always drawn, dimly: a handle you have to hover to discover is a handle
    /// nobody discovers. The grab area underneath is an AppKit view (`DragHandle`)
    /// — a SwiftUI gesture here moved the panel instead of the row — and it also
    /// swallows a plain click, which is not a click on the row and must not open
    /// anything.
    private func handle(_ drag: RowDragState) -> some View {
        ZStack {
            DragHandle(onChanged: drag.onChanged, onEnded: drag.onEnded)
            // Neutral, because a project belongs to no single agent. The
            // tinted grips are on the conversations inside it, and both come from
            // one view so they cannot drift apart again.
            AgentGrip(harness: nil, bright: hovering || drag.isDragged, height: height)
                .allowsHitTesting(false)
        }
        .frame(width: 14, height: height)
    }



    // MARK: - Interaction

    /// Alt+click peeks: it raises the window without consuming the green.
    ///
    /// `markedSeen` is irreversible by construction, and that is fine — but
    /// without an escape hatch one click too many erases an answer nobody read.
    /// The menu entry exists because a modifier nobody discovers is dead code.
    private func activate() {
        // A sample has no folder, no conversation and no window: whatever the
        // modifiers, a click only reads it (U4).
        if isSample { actions.open(row); return }
        let modifiers = NSEvent.modifierFlags

        // A project holding several conversations is a heading, and a plain click
        // on it opens and closes. It used to raise "the most urgent", which
        // between two conversations both working was decided by our tie-breaking
        // rather than by anybody: an ambiguous destination traded for an honest
        // one. The modifiers still mean what they meant, and the bound key still
        // opens in one press, because that is a gesture made without looking.
        if row.count > 1, modifiers.isDisjoint(with: [.command, .option, .shift]) {
            actions.toggleExpansion(row)
            return
        }

        if modifiers.contains(.command), !row.workspace.isRemote {
            activateChat()
        } else if modifiers.contains(.option) {
            actions.peek(row)
        } else if modifiers.contains(.shift), !row.workspace.isRemote {
            // The fast path for the glyph that only appears on hover. Both exist
            // for the same reason the other two modifiers do: the gesture is for
            // whoever knows it, the menu is how anybody finds out it is there.
            actions.revealInFinder(row)
        } else {
            actions.open(row)
        }
    }

    /// ⌘+click opens the extended window on this conversation.
    ///
    /// The modifier and the menu entry both exist for the same reason alt+click
    /// does: the gesture is the fast path for people who know it, the menu is how
    /// anybody finds out it is there.
    private func activateChat() {
        actions.openChat(row)
    }

    /// The row's menu (U3): eight entries, the ways of keeping it quiet under
    /// Quiet and the rarer things under More, built in Core (`Menus.row`).
    @ViewBuilder
    private var menu: some View {
        // A sample row's menu offers the one thing that makes sense for an
        // invented row: taking the samples away. Hide, rename, focus and the rest
        // would write preferences about a folder that does not exist (U4).
        if isSample {
            Button("Remove the samples", action: actions.removeSamples)
        } else {
            realMenu
        }
    }

    private var isSample: Bool { Samples.isSample(row.primary.id) }

    private var realMenu: some View {
        let repository = row.workspace.isRemote ? nil : row.primary.git?.repo
        let target = actions.liveTarget(row.primary)
        let state = RowMenuState(
            isRemote: row.workspace.isRemote, compact: compact, alias: row.alias, folder: row.workspace.name,
            status: row.status, isHidden: flags.isHidden, isCalm: flags.isCalm, isMuted: flags.isMuted,
            isFocused: flags.isFocused, notificationsEnabled: flags.notificationsEnabled,
            hostsNewConversation: row.hostsNewConversation, repository: repository,
            pinned: repository.map(actions.decisions) ?? [], attachCommand: target?.command,
            modelOffer: actions.governorOffer(row)?.title, canMoveHere: actions.canMoveHere(row.primary)
        )
        return MenuEntriesView(entries: Menus.row(state)) { command in
            switch command {
            case .open: actions.open(row)
            case .read: actions.openChat(row)
            case .sessionView: actions.openPlancia(row)
            case .newConversation: actions.newConversation(row)
            case .rename: actions.rename(row)
            case .hide: actions.toggleHidden(row)
            case .dontAlert: actions.toggleMuted(row)
            case .dontBlink: actions.toggleCalmBlink(row)
            case .focus: actions.toggleFocus(row)
            case .peek: actions.peek(row)
            case .markUnread: actions.markUnread(row)
            case .moveUp: actions.move(row, -1)
            case .moveDown: actions.move(row, 1)
            case .revealInFinder: actions.revealInFinder(row)
            case .pinDecision: if let repository { actions.pinDecision(repository) }
            case .unpinDecision(let number): if let repository { actions.unpinDecision(repository, number) }
            case .copyAttach: if let target { actions.copyCommand(target.command) }
            case .openHere: if let target { actions.openHere(target) }
            case .startHere: actions.startHere(row)
            case .moveHere: actions.moveHere(row)
            case .toggleModel: actions.toggleModel(row)
            default: break
            }
        }
    }

    // MARK: - Content

    /// The badge next to the name: how many sessions, or how many subagents.
    ///
    /// The two pieces of information don't share the same space, so the winner is
    /// the one saying something rarer: subagents at work explain *why* the row is
    /// yellow, the session count does not.
    /// The two facts used to fight over one cell, and the rule was "the rarer one
    /// wins". They are different kinds of fact and now have different homes: how
    /// many conversations is about the row's **structure** and sits with the
    /// chevron, how many subagents is about the **current turn** and stays here.
    /// Not on a block. The number there is a **sum** across the project, so three
    /// subagents in one conversation and one each in three read the same, and it
    /// was competing for the line with the count of conversations. Reported from
    /// use: with both badges present the name disappeared. Inside an opened block
    /// each line carries its own, where it is true.
    private var badge: String? {
        guard row.count == 1, row.activeSubagents > 0 else { return nil }
        return "×\(row.activeSubagents)"
    }

    /// The state the dot is covering, if any: the other half of "most urgent".
    ///
    /// Hidden while the block is open, where it would repeat something already
    /// visible on the line below it.
    private var recall: some View {
        Group {
            if !flags.isExpanded, let covered = row.recalledStatus {
                Circle()
                    .fill(StatusPalette.color(for: covered))
                    .frame(width: 7, height: 7)
            }
        }
    }

    /// How many conversations are in here, and which way they are.
    ///
    /// The count already appeared only when there was more than one, so it was
    /// already the sign that a project holds several. Giving it the chevron makes
    /// it say the other half without a new mark, and it costs nothing on the rows
    /// that will never open, which is most of them.
    private var blockBadge: some View {
        Group {
            if row.count > 1 {
                HStack(spacing: 3) {
                    // The number only while it is closed. Open, the lines are
                    // right there and countable, and those ten points are worth
                    // more to the name: `Clawd Light Cod` came out as `Cla…Cod`,
                    // which is not a name.
                    if !flags.isExpanded {
                        Text("\(row.count)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    Image(systemName: flags.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(StatusPalette.badgeForeground)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(StatusPalette.badgeBackground))
                .fixedSize()
            }
        }
    }

    /// What the right-hand slot shows.
    ///
    /// Not always a timestamp, because the timestamp isn't always the useful
    /// information: on a working session what counts is *how long* (`42m` reads in
    /// half a second, `08:14` has to be computed), and on an interrupted turn what
    /// counts is *why*. The timestamp stays in the tooltip in both cases.
    private var timeLabel: String {
        switch row.status {
        case .working, .waiting:
            // A quarter of an hour on one tool: how long on *that*, marked (5.7).
            if let stuck = row.primary.stuckTool(at: now) {
                return "⌛ " + CompactDuration.label(seconds: now.timeIntervalSince(stuck.since))
            }
            return CompactDuration.label(seconds: row.primary.statusDuration(at: now))
        case .failed:
            return (row.primary.failureReason ?? .unknown).shortLabel
        case .idle, .awaiting, .ready:
            return RelativeTime.label(for: row.updatedAt, now: now)
        }
    }

    /// An idle session dims, but stays readable: same reason the timestamp doesn't
    /// use the weak semantic hues over vibrancy.
    private var labelColor: Color {
        row.status == .idle ? Color.primary.opacity(0.72) : .primary
    }

}
