import AppKit
import Combine
import LampBoardCore

/// What waits, wired into the panel (D74, U2): where its cards come from, what
/// its keys do, and when an ask under a row makes the window grow.
///
/// Its own file for the reason `PanelAllowance.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    func wireQueue() {
        queue.onOpen = { [weak self] id in
            guard let self, let session = self.session(named: id) else { return }
            self.activate(session: session)
        }
        queue.onMarkRead = { [weak self] ids in
            ids.forEach { self?.store.markSeen(sessionId: $0) }
        }
        queue.onAnswer = { [weak self] session, call, verdict in
            self?.permissionDesk?.answer(session: session, call: call, verdict) ?? false
        }
        queue.onChoose = { [weak self] session, call, index in
            self?.permissionDesk?.choose(session: session, call: call, index: index) ?? false
        }
        queue.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.resizeToFit(self.store.state)
        }
        // Keys only while the panel holds the keyboard, which it does after a
        // click on it and never by itself: typing in an editor is never read.
        // And only where the queue is drawn: the narrow panel has none, and a
        // key acting on a card nobody can see would be a review finding twice.
        queue.holdsKeyboard = { [weak self] in
            guard let self else { return false }
            return self.panel.isKeyWindow && !self.isCompact && !self.bar.isEditing && !self.isTyping
        }
        queue.startListening()
        for (name, active) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.publisher(for: name, object: panel)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.queue.keyboard(active: active)
                    // The line said on return goes at the first gesture (U2):
                    // read, it has done its job, and it should not sit there.
                    if active { self?.dismissAwayNote() }
                }
                .store(in: &cancellables)
        }
        // An ask the panel holds comes and goes with the mod, not with a hook.
        permissionDesk?.$pending
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshQueue() }
            .store(in: &cancellables)
        // A turn becomes stuck by time alone, with no event to say so; and a row
        // folds under «Resting» by time alone too (U2), so the window is
        // remeasured on the same beat.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshQueue()
                // The view and the window must fold the same rows at the same
                // moment: a fold by time alone redraws the column, not just the
                // window, or one of them is a row short for up to a minute.
                let resting = ColumnLayout.render(self.store.state, options: self.columnOptions, now: Date())
                    .resting?.rows.map(\.id) ?? []
                if resting != self.restingDrawn { self.rebuildContent() } else { self.resizeToFit(self.store.state) }
            }
            .store(in: &cancellables)
        refreshQueue()
    }

    /// LampMaster's suggestions stay out: they are its star in the bar now (U2),
    /// and J and K walk the rows that wait.
    func refreshQueue() {
        queue.refresh(sessions: Array(store.state.sessions.values), suggestions: [],
                      asks: permissionDesk?.pending ?? [], returned: permissionDesk?.returned ?? [])
    }

    func dismissAwayNote() {
        guard store.awayNote != nil else { return }
        store.awayNote = nil
        resizeToFit(store.state)
    }

    /// Opens or folds the «Resting» line (U2).
    func toggleResting() {
        preferences.showsResting.toggle()
        rebuildContent()
    }

    /// Three sample rows in the real panel (U4), in the wide panel where their
    /// second lines can be read.
    func startSamples() {
        summon()
        if isCompact { toggleCompact() }
        samples.start()
    }
}
