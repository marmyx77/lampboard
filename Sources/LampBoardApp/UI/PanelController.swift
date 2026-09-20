import AppKit
import LampBoardCore
import Combine
import SwiftUI

/// Holds panel, views and preferences together.
///
/// The height follows the number of rows: a widget that takes up space for rows
/// that don't exist is a widget the user moves into a corner and stops looking at.
@MainActor
final class PanelController {

    let store: StateStore
    private let installer: HookInstaller
    let preferences: Preferences
    let panel: FloatingPanel

    private var compact: Bool
    /// Not private: `PanelAllowance.swift` subscribes here too, for the same
    /// reason it exists — the subject was taken out whole to keep this file under
    /// the eight hundred lines the project refuses to cross.
    var cancellables = Set<AnyCancellable>()

    /// The lamp in the menu bar. It exists whether or not the panel lives up
    /// there: two surfaces, one column, and the switch for each is its own.
    let lamp = MenuBarLamp()
    var home: PanelHome

    /// Holds the click a missing permission interrupted, until it can be finished.
    private let permissions = PermissionWatcher()

    /// The extended window: the conversation list plus the selected conversation.
    /// Opened on request; the panel is the resting state.
    private lazy var chats = ChatWindowController(
        store: store,
        preferences: preferences
    ) { [weak self] session in
        self?.activate(session: session)
    }

    /// Called from outside to turn notifications on or off.
    /// Opens the Settings window; set by whoever owns it.
    var onOpenSettings: (() -> Void)?
    var onOpenLegend: (() -> Void)?

    var onNotificationToggle: ((Bool) -> Void)?

    init(store: StateStore, installer: HookInstaller, preferences: Preferences = Preferences()) {
        self.store = store
        self.installer = installer
        self.preferences = preferences
        self.compact = preferences.isCompact
        self.home = preferences.home

        let size = NSSize(
            width: Layout.width(compact: compact),
            height: Layout.height(ofBlocks: [], extras: 0, showsIssue: false)
        )
        self.panel = FloatingPanel(
            contentRect: Preferences.placed(
                size: size, anchor: preferences.savedAnchor, on: NSScreen.main
            )
        )
    }

    // MARK: - Lifecycle

    func show() {
        // Before anything else. No chat window can be open at this instant, so
        // every marker on disk belongs to a previous run, and every message
        // listener still waiting on one is holding a process for a window that
        // died with it. Left unreaped they accumulate one per crash per session.
        chats.reapStaleMailboxes()

        wireLamp()
        // Whatever the switch was left on last time. Off is the default and costs
        // nothing; on has to resume by itself, or the feature would look like it
        // had forgotten between launches.
        allowance.hosts = preferences.remoteHosts
        allowance.apply(enabled: preferences.usageEnabled)
        rebuildContent()
        applyHome(showing: home == .floating)
        logPanelState()
        observeStore()
        observeAllowance()
        observePanelMoves()
    }

    func close() {
        chats.close()
        lamp.hide()
        panel.close()
    }

    /// Kept alive for as long as the menu is: `NSMenuItem.target` is weak, and a
    /// target that has been released is an entry that quietly does nothing.
    var menuTargets: [MenuAction] = []

    /// Opens the chat window for the project bound to a slot, for `chat <n>`.
    ///
    /// - Returns: what it opened, or `nil` when the slot holds nothing — the same
    ///   answer `open <n>` gives, for the same reason.
    @discardableResult
    func openChatInSlot(_ slot: Int) -> String? {
        let rendering = ColumnLayout.render(store.state, options: columnOptions)
        guard let row = rendering.row(inSlot: slot) else { return nil }
        openChat(in: row)
        return "\(row.displayName): \(row.status.label)"
    }

    /// `true` when the panel really is under the user's eyes.
    /// Used by the notification gate, which treats it as a hint rather than the
    /// truth: `occlusionState` knows how to lie.
    var isPanelVisible: Bool {
        panel.isVisible && panel.occlusionState.contains(.visible)
    }

    private func logPanelState() {
        Diagnostics.log("""
        panel: visible=\(panel.isVisible) frame=\(panel.frame) \
        alpha=\(panel.alphaValue) onActiveSpace=\(panel.isOnActiveSpace) \
        occlusion=\(panel.occlusionState.contains(.visible) ? "visible" : "occluded") \
        level=\(panel.level.rawValue) contentBounds=\(panel.contentView?.bounds ?? .zero) \
        policy=\(NSApp.activationPolicy().rawValue) screens=\(NSScreen.screens.count) \
        signature=\(CodeSignature.isAdHoc ? "ad-hoc" : "stable") \
        accessibility=\(VSCodeFocuser.hasAccessibilityPermission ? "granted" : "MISSING")
        """)
        // The permission has to be read **by the process that will use it**.
        // Asking from a terminal answers for Terminal: macOS attributes the access
        // to the "responsible process", which for a binary launched from a shell is
        // the shell. It is the same deception as verifying the matching with
        // `osascript` instead of `NSAppleScript` — different tool, different
        // answer, wrong conclusion.
    }

    // MARK: - Updating

    private func observeStore() {
        store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                // A project seen for the first time has just been given a place
                // (`StateStore.givePlaces`). The view holds its options by value,
                // so it has to be rebuilt to learn about it; every other change
                // is a resize.
                if self.columnOptions != self.renderedOptions {
                    self.rebuildContent()
                } else {
                    self.resizeToFit(state)
                }
                // The lamp is a summary of the column, so it learns from the same
                // change and at the same instant. Anything else and the two could
                // disagree, with the one that has no room to explain itself being
                // the one somebody is reading from across the room.
                self.lamp.update(self.currentSummary)
            }
            .store(in: &cancellables)

        // Renaming does not touch `store.state`, so the observer above never runs
        // and the row keeps the name it was drawn with until an unrelated event
        // arrives. Reported from use: the new name is saved — reopening the dialog
        // shows it — and the column disagrees with the dialog for as long as the
        // session stays quiet.
        //
        // The panel's own menu got away with it by calling `rebuildContent()`
        // itself; the chat window did not, and neither would the next caller. So
        // the trigger belongs here, on the preferences, rather than on every
        // place that writes one: any change to a name, an order, a slot or a
        // hidden project rebuilds, and `columnOptions != renderedOptions` throws
        // away the changes that do not concern the column.
        //
        // `UserDefaults` posts this inside the process that wrote it, so `lampboard
        // rename` from another process is still picked up at the next state
        // change, as it was before.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: Preferences.sharedDefaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Hiding a project and silencing one both live here, and both
                // change what the lamp should say.
                self.lamp.update(self.currentSummary)
                guard self.columnOptions != self.renderedOptions else { return }
                self.rebuildContent()
            }
            .store(in: &cancellables)

        // The strip appears and disappears under the rows, so the panel has to
        // find room for it. Without this the strip shows up inside the footer's
        // space and the gear is pushed off the bottom edge — which is how the
        // last version of this footer was already learned, the hard way.
        store.$issue
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resizeToFit(self.store.state)
            }
            .store(in: &cancellables)
    }

    private func observePanelMoves() {
        NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                guard let self else { return }
                // A drop-down is put where the lamp is, not where anybody dragged
                // it. Saving that would overwrite the corner the floating panel
                // was left in, and it would be found the next time somebody
                // brought the panel back and it came back somewhere else.
                guard self.home == .floating else { return }
                self.preferences.saveAnchor(PanelPlacement.anchor(of: self.panel.frame))
            }
            .store(in: &cancellables)
    }

    /// The rows exactly as the panel is drawing them at this moment.
    ///
    /// The legend counts through this rather than through the state, so that a
    /// census and a column can never disagree: same renderer, same options, same
    /// hidden projects left out of both.
    var currentRendering: ColumnRendering {
        ColumnLayout.render(store.state, options: columnOptions)
    }

    /// The layout options derived from the preferences.
    private var columnOptions: ColumnOptions {
        ColumnOptions(
            onlyWaiting: preferences.showsOnlyWaiting,
            order: preferences.rowOrder,
            hidden: preferences.hiddenWorkspaces,
            names: preferences.rowNames,
            conversationOrder: preferences.conversationOrder
        )
    }

    /// The options the current content was built with.
    private var renderedOptions: ColumnOptions?

    /// The account's allowance. Created whatever the preference says, and asked
    /// nothing until `apply(enabled:)` is told otherwise: an object that exists is
    /// free, a timer that runs is not. Not private: the switch that drives it lives
    /// in `PanelAllowance.swift`.
    let allowance = AllowanceMonitor()

    func rebuildContent() {
        let root = PanelRootView(
            store: store,
            flags: panelFlags,
            options: columnOptions,
            mutedWorkspaces: preferences.mutedWorkspaces,
            calmWorkspaces: preferences.calmBlinkWorkspaces,
            expandedRows: preferences.expandedRows,
            actions: makeActions(),
            rowActions: makeRowActions(),
            allowance: allowance
        )
        panel.contentView = NSHostingView(rootView: root)
        renderedOptions = columnOptions
        resizeToFit(store.state)
    }

    private var panelFlags: PanelFlags {
        PanelFlags(
            compact: compact,
            home: home,
            showsMenuBarIcon: preferences.showsMenuBarIcon || home.requiresMenuBarIcon,
            opensSessionTab: preferences.opensSessionTab,
            onlyWaiting: preferences.showsOnlyWaiting,
            notificationsEnabled: preferences.notificationsEnabled,
            messageSendingEnabled: preferences.messageSendingEnabled,
            presenceEnabled: preferences.presenceEnabled,
            usageEnabled: preferences.usageEnabled,
            showsTerminalSessions: preferences.showsTerminalSessions,
            mutedUntil: preferences.mutedUntil,
            hasHidden: !preferences.hiddenWorkspaces.isEmpty,
            hooksInstalled: !HookSetup.needsInstalling(),
            hooksMissingFrom: HookSetup.missingNames(),
            launchesAtLogin: LaunchAtLogin.isEnabled,
            canLaunchAtLogin: LaunchAtLogin.availability != .needsBundle
        )
    }

    /// Recomputes the height keeping the top edge fixed: the panel grows downwards,
    /// so the corner the user put it in doesn't move.
    func resizeToFit(_ state: TrafficLightState) {
        let rendering = ColumnLayout.render(state, options: columnOptions)
        // The service rows — hidden summary, filter note — take up as much space
        // as the others and have to be counted, otherwise the last one ends up
        // clipped.
        let extras = (rendering.hidden != nil ? 1 : 0) + (rendering.filteredOut > 0 ? 1 : 0)

        // Measured with the same function the column lays out with. They used to
        // be two formulas that agreed right up until a project was opened, and
        // then disagreed by the padding a block adds: with two open, the window
        // came up twelve points short and the last row was cut in half.
        let blocks = rendering.rows.map { row -> CGFloat in
            let open = row.count > 1 && preferences.expandedRows.contains(row.id)
            let shown = open ? min(row.members.count, Layout.subRowCap) : 0
            return Layout.blockHeight(
                rowCount: row.count,
                shownConversations: shown,
                hasTail: open && row.members.count > shown,
                compact: compact
            )
        }

        let wanted = NSSize(
            width: Layout.width(compact: compact),
            height: Layout.height(
                ofBlocks: blocks, extras: extras, showsIssue: store.issue != nil,
                allowanceLines: allowance.reports.count
            )
        )

        // Clamped to what the display can show. Without this an opened project on
        // a long column walks the panel off the bottom of the screen, which is the
        // same defect as hiding a row, only harder to notice. Past that the column
        // scrolls, which is the honest answer for somebody with twenty sessions.
        let ceiling = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? wanted.height
        let size = NSSize(width: wanted.width, height: min(wanted.height, ceiling))

        guard size != panel.frame.size else { return }

        // Every resize says what it was computing from. A panel that changes
        // height twice per sweep looks like a fault in the drawing and is
        // usually a disagreement between two readings of the same state, so the
        // readings are named rather than guessed at.
        Diagnostics.log(
            "resize: \(Int(panel.frame.height)) -> \(Int(size.height)) "
                + "[rows \(rendering.rows.count), open "
                + "\(rendering.rows.filter { preferences.expandedRows.contains($0.id) }.count), "
                + "sessions \(state.sessions.count), extras \(extras), "
                + "issue \(store.issue != nil), ceiling \(Int(ceiling))]"
        )

        // Hung from the top it already has, and kept whole on the screen. The
        // second half is the one that was missing: the height was bounded and
        // the position was not, so an opened project pushed the bottom of the
        // panel under the edge of the display — and the move that did it was
        // saved, so the next launch started lower still.
        // In the menu bar the panel hangs from the lamp rather than from wherever
        // it was last dragged. It still grows downward from a fixed top; the fixed
        // top is the bar. Re-hanging it on every resize is also what stops a
        // drop-down walking down the screen as sessions appear.
        guard home != .menuBar else {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
            positionUnderLamp()
            return
        }

        panel.setFrame(
            Preferences.placed(
                size: size,
                anchor: PanelPlacement.anchor(of: panel.frame),
                on: panel.screen
            ),
            display: true, animate: false
        )
    }


    // MARK: - Row actions

    private func makeRowActions() -> RowActions {
        RowActions(
            open: { [weak self] row in self?.activate(row, markSeen: true) },
            peek: { [weak self] row in self?.activate(row, markSeen: false) },
            markUnread: { [weak self] row in self?.markUnread(row) },
            move: { [weak self] row, offset in
                guard let self else { return }
                preferences.rowOrder = RowOrder.moving(
                    row.workspace.key, by: offset, among: visibleKeys(), in: preferences.rowOrder
                )
                rebuildContent()
            },
            place: { [weak self] row, index in
                guard let self else { return }
                preferences.rowOrder = RowOrder.placing(
                    row.workspace.key, at: index, among: visibleKeys(), in: preferences.rowOrder
                )
                rebuildContent()
            },
            toggleHidden: { [weak self] row in
                guard let self else { return }
                preferences.hiddenWorkspaces = Preferences.toggling(
                    row.workspace.key, in: preferences.hiddenWorkspaces
                )
                rebuildContent()
            },
            toggleMuted: { [weak self] row in
                guard let self else { return }
                preferences.mutedWorkspaces = Preferences.toggling(
                    row.workspace.key, in: preferences.mutedWorkspaces
                )
                rebuildContent()
            },
            toggleCalmBlink: { [weak self] row in
                guard let self else { return }
                preferences.calmBlinkWorkspaces = Preferences.toggling(
                    row.workspace.key, in: preferences.calmBlinkWorkspaces
                )
                rebuildContent()
            },
            newConversation: { [weak self] row in self?.newConversation(in: row) },
            openChat: { [weak self] row in self?.openChat(in: row) },
            rename: { [weak self] row in self?.rename(row) },
            toggleExpansion: { [weak self] row in self?.toggleExpansion(row) },
            openSession: { [weak self] member in self?.activate(session: member) },
            renameSession: { [weak self] member in self?.rename(session: member) },
            dismissSession: { [weak self] member in self?.dismiss(session: member) },
            terminateSession: { [weak self] member in self?.terminate(session: member) },
            moveSession: { [weak self] row, member, offset in
                self?.move(member, in: row, by: offset)
            },
            revealInFinder: { row in FinderReveal.open(row.workspace.path) }
        )
    }

    /// The projects drawn right now, top to bottom: what a drag or a "move" is
    /// relative to. The full order also holds hidden, filtered and sessionless
    /// projects, which the user cannot see and therefore cannot mean.
    ///
    /// Keys rather than paths, because the same path on two machines is two
    /// projects and moving one must not move the other. See `Workspace.key`.
    private func visibleKeys() -> [String] {
        ColumnLayout.render(store.state, options: columnOptions).rows.map(\.workspace.key)
    }

    /// Opens the row's conversation in a window of its own.
    ///
    /// It marks the row as seen exactly like a click on the editor would: reading
    /// the answer here is reading it. Leaving the row green because the reading
    /// happened in the wrong window would be a distinction only the code cares
    /// about.
    ///
    /// It opens the same session a click opens — `primary`, the most urgent one —
    /// so the two gestures never disagree about which conversation this row is.
    func openChat(in row: ColumnRow) {
        for id in row.sessionIdsToClear { store.markSeen(sessionId: id) }
        chats.show(selecting: row.primary.id)
    }

    /// Opens the extended window without choosing a conversation, for the menu.
    func openExtendedWindow() {
        chats.show()
    }

    /// Brings the window to the front and, if asked, clears the unread state.
    ///
    /// `markSeen` false is alt+click: it raises the window and leaves the row as it
    /// is. It exists because `markedSeen` is irreversible and one click too many
    /// would erase an answer nobody ever read.
    /// - Parameter opensTab: `false` brings the window forward **without** opening
    ///   the session's tab. Needed by "new conversation", which would otherwise
    ///   open two: first the existing one and then the new one.
    // MARK: - Updates

    func checkForUpdates() {
        Task { @MainActor in
            await UpdateFlow.run(
                report: { [weak self] in self?.store.reportError($0) },
                clear: { [weak self] in self?.store.clearError() }
            )
        }
    }

    // MARK: - Waiting for a permission

    /// Hands the interrupted click to the watcher, for the permissions it can
    /// honestly wait on.
    ///
    /// Automation towards a terminal application is not one of them: asking *is*
    /// using it, so there is no way to poll without sending an Apple Event every
    /// second and no way to tell "denied" from "not asked yet". That one is
    /// retried by the next click.
    func awaitPermission(for error: FocusError, retry: @escaping () -> Void) {
        guard case .accessibilityDenied = error else { return }
        permissions.watch(retry: retry) { [weak self] in
            guard let self else { return }
            self.store.clearError()
            self.rebuildContent()
        }
    }

    /// The click on a terminal row: seat first, then the focuser for that seat.
    func activateTerminal(_ session: SessionState) {
        let name = session.displayName
        let seat: Seat
        let chain: [ProcessAncestor]
        switch SeatResolver.resolve(session: session) {
        case .failure(let error):
            store.reportError("“\(name)” cannot be raised: \(error.short).")
            return
        case .success(let found):
            seat = found.seat
            chain = found.chain
        }
        Diagnostics.log("seat of \(session.id.prefix(8)): \(seat.label)")

        let result: VSCodeFocuser.FocusResult
        if case .editor = seat {
            // An editor's own terminal, in a folder no window claims (an empty
            // window, say): the editor is the place, raised the way editor rows are.
            result = VSCodeFocuser.focus(workspace: session.workspace, sessionId: nil)
        } else {
            result = TerminalFocuser.focus(
                seat: seat,
                context: TerminalFocuser.Context(
                    cwd: session.workspace.path, title: session.title, pids: Set(chain.map(\.pid))
                )
            )
        }

        switch result {
        case .raised:
            store.clearError()
        case .activatedOnly(let reason):
            store.reportError(
                "“\(name)”: only \(seat.label) was activated (\(reason.shortDescription)).",
                issue: reason.panelIssue
            )
            awaitPermission(for: reason) { [weak self] in self?.activateTerminal(session) }
        case .failed(let error):
            store.reportError(
                "“\(name)” runs in \(seat.label): \(error.shortDescription).",
                issue: error.panelIssue
            )
            awaitPermission(for: error) { [weak self] in self?.activateTerminal(session) }
        }
    }

    /// Restores every cleared session in the row to "unread".
    private func markUnread(_ row: ColumnRow) {
        for session in row.sessions where session.status == .idle {
            store.markUnread(sessionId: session.id)
        }
    }

    /// Opens a new Claude tab in the row's project.
    ///
    /// The same deep link as the click, without the session parameter: with no
    /// `session` the extension opens a new conversation instead of reattaching to
    /// an existing one.
    private func newConversation(in row: ColumnRow) {
        // There is no tab to open one in: the deep link would land in whatever
        // editor window has the focus, which is a conversation in the wrong
        // project — the mess this gate exists to prevent.
        guard row.hostsNewConversation else {
            store.reportError(
                row.isTerminal
                    ? "\u{201C}\(row.displayName)\u{201D} runs in a terminal: start the new conversation there."
                    : "\u{201C}\(row.displayName)\u{201D} does not host Claude Code conversations."
            )
            return
        }
        activate(row, markSeen: false, opensTab: false)
        VSCodeFocuser.openNewConversation(in: row.workspace)
    }

    /// The next waiting session, for the shortcut and for `next`.
    /// - Returns: a description of what was raised, or `nil` when there was nothing.
    @discardableResult
    func activateNextWaiting() -> String? {
        let rendering = ColumnLayout.render(store.state, options: columnOptions)
        guard let row = rendering.rows.first(where: { $0.status.clearsOnFocus }) else {
            return nil
        }
        activate(row, markSeen: true)
        return "\(row.displayName): \(row.status.label)"
    }

    /// Raises the project bound to a slot, for `open <n>`.
    ///
    /// - Returns: a description of what was raised, or `nil` when the slot holds
    ///   nothing. Empty is an ordinary answer, not a failure: a project can be
    ///   pinned and have no live session at this moment. What must never happen
    ///   is opening the neighboring row instead — for a key pressed without
    ///   looking, that is the worst possible behavior.
    @discardableResult
    func activateSlot(_ slot: Int) -> String? {
        let rendering = ColumnLayout.render(store.state, options: columnOptions)
        guard let row = rendering.row(inSlot: slot) else { return nil }
        activate(row, markSeen: true)
        return "\(row.displayName): \(row.status.label)"
    }

    /// Opens a new conversation in the project bound to a slot, for `new <n>`.
    ///
    /// The Codex Micro has "start new chat" as a command key next to the Agent
    /// Keys; this is the same gesture, addressed the same way. It is the only one
    /// of its command keys that survives — the others act on a session already
    /// running, which the extension refuses (N7).
    ///
    /// - Returns: a description of where it opened, or `nil` when the slot holds
    ///   nothing. Silence rather than a guess, exactly like `activateSlot`.
    @discardableResult
    func newConversationInSlot(_ slot: Int) -> String? {
        let rendering = ColumnLayout.render(store.state, options: columnOptions)
        guard let row = rendering.row(inSlot: slot), row.hostsNewConversation else { return nil }
        newConversation(in: row)
        return row.displayName
    }

    /// What each slot currently addresses, for the CLI listing.
    func slotAssignments() -> [(slot: Int, name: String, status: String)] {
        ColumnLayout.render(store.state, options: columnOptions)
            .occupiedSlots
            .map { (slot: $0.slot, name: $0.row.displayName,
                    status: $0.row.status.rawValue) }
    }

    /// Opens the given session: used by the click on a notification.
    ///
    /// The synthetic row carries no slot, and that is correct rather than lazy:
    /// this row never reaches the column, it only exists to hand `activate` a
    /// workspace and a session to clear. A slot here would be a fact about a
    /// drawing that isn't being drawn.
    func activate(session: SessionState) {
        activate(
            ColumnRow(
                id: session.id,
                workspace: session.workspace,
                sessions: [session]
            ),
            markSeen: true
        )
    }

    // MARK: - Panel actions

    func toggleCompact() {
        compact.toggle()
        preferences.isCompact = compact
        rebuildContent()
    }

    /// Turning notifications on makes the system prompt appear, and this is the
    /// right moment: the user has just asked for the feature.
    func toggleNotifications() {
        let wanted = !preferences.notificationsEnabled
        preferences.notificationsEnabled = wanted
        onNotificationToggle?(wanted)
        rebuildContent()
    }

    /// Turns answering from the panel on or off.
    ///
    /// Turning it **on** registers the delivery hook; turning it off removes it,
    /// so the resting state of a machine that never opted in has no listener, no
    /// mailbox and no way for anything to start a turn in the user's name.
    ///
    /// The dialog says what it costs, because this is the one switch here whose
    /// default is about safety rather than noise.
    func toggleMessageSending() {
        let wanted = !preferences.messageSendingEnabled

        if wanted {
            guard Alerts.confirm(
                title: "Let the panel answer your sessions?",
                message: """
                You will be able to type and dictate into the conversation window, \
                and the message will reach the session at the end of its next turn.

                What it costs: delivery works through a file in ~/.lampboard/inbox, \
                and the reader cannot tell who wrote it. While this is on, anything \
                running under your account can start a turn that speaks with your \
                voice and your tools. Other accounts on this Mac are kept out; \
                processes of your own cannot be.

                Off, there is no listener and no mailbox at all, and the window \
                still shows you every conversation.
                """,
                confirmTitle: "Turn on"
            ) else { return }
        }

        preferences.messageSendingEnabled = wanted
        reinstallHooksForMessageSending()
        rebuildContent()
    }

    /// Re-registers the hooks so the delivery listener follows the switch.
    ///
    /// Claude Code alone, and deliberately: message delivery rides a second
    /// `Stop` hook that answers a mailbox, and Codex has no path back into a
    /// session to answer through. Everything else about installing goes through
    /// `HookSetup` and reaches both agents; this one thing is not shared because
    /// only one agent has it.
    private func reinstallHooksForMessageSending() {
        guard installer.isInstalled() else { return }
        do {
            try installer.install(includeMessageDelivery: preferences.messageSendingEnabled)
        } catch {
            store.reportError(error.localizedDescription)
        }
    }

    func togglePresence() {
        let wanted = !preferences.presenceEnabled
        preferences.presenceEnabled = wanted

        if wanted {
            Alerts.info(
                title: "Phone push notifications suppressed while you're at the Mac",
                message: """
                Claude Code will skip the notifications on your phone for as long as \
                lampboard declares your presence.

                For this to work, the CLAUDE_CLIENT_PRESENCE_FILE variable has to \
                point at \(AppConfig.presenceFileURL.path).

                Careful: if the detection gets it wrong, the result is not one \
                notification too many but a notification lost.
                """
            )
        }
        rebuildContent()
    }

    /// "Show terminal sessions" (D25). Off takes its rows away at once; on lets
    /// the next poll adopt what is there, within five seconds.
    func toggleTerminalSessions() {
        let wanted = !preferences.showsTerminalSessions
        preferences.showsTerminalSessions = wanted
        if wanted {
            store.poll()
        } else {
            store.forgetTerminalSessions()
        }
        rebuildContent()
    }

    func toggleLaunchAtLogin() {
        if let failure = LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled) {
            Alerts.warn(title: "Launch at login", message: failure)
        }
        rebuildContent()
    }

    func installHooks() {
        // Every agent on this machine, and the alert names them: the menu used
        // to say "in Claude Code" and mean it, leaving Codex unregistered for
        // anyone who never opened a terminal to run the installer.
        let agents = HookSetup.state()
            .filter { $0.outcome != .notPresent }
            .map(\.harness.displayName)
            .joined(separator: " and ")

        guard Alerts.confirm(
            title: "Install the hooks?",
            message: """
            lampboard will register \(HookConfigMerger.defaultEvents.count) hooks in the \
            configuration of \(agents), so it knows when sessions change state.

            Existing hooks are preserved and a backup copy of each file is created. \
            Sessions that are already open pick up the new configuration the next \
            time they start.
            """,
            confirmTitle: "Install"
        ) else { return }

        let reports = HookSetup.install(includeMessageDelivery: preferences.messageSendingEnabled)
        rebuildContent()
        guard !HookSetup.hasFailure(in: reports) else {
            let summary = HookSetup.summary(of: reports)
            store.reportError(summary)
            Alerts.warn(title: "Not everything was installed", message: summary)
            return
        }
        Alerts.info(title: "Hooks installed", message: HookSetup.summary(of: reports))
    }

    func uninstallHooks() {
        let reports = HookSetup.remove()
        rebuildContent()
        guard !HookSetup.hasFailure(in: reports) else {
            let summary = HookSetup.summary(of: reports)
            store.reportError(summary)
            Alerts.warn(title: "Removal failed", message: summary)
            return
        }
        Alerts.info(
            title: "Hooks removed",
            message: "lampboard will no longer receive signals from either agent."
        )
    }
}
