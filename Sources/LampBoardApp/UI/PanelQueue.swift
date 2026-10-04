import AppKit
import Combine
import LampBoardCore

/// "Waiting for you" wired into the panel (D74): where its cards come from,
/// what its keys do, and when it makes the window grow.
///
/// Its own file for the reason `PanelAllowance.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    func wireQueue() {
        queue.onOpen = { [weak self] id in
            guard let self, let session = self.store.state.sessions[id] else { return }
            self.activate(session: session)
        }
        queue.onMarkRead = { [weak self] ids in
            ids.forEach { self?.store.markSeen(sessionId: $0) }
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
            return self.panel.isKeyWindow && !self.isCompact
        }
        queue.startListening()
        for (name, active) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.publisher(for: name, object: panel)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.queue.keyboard(active: active) }
                .store(in: &cancellables)
        }

        // LampMaster's card comes and goes with its rounds, not with a session.
        lampMaster?.$snapshot
            .map(\.open)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshQueue() }
            .store(in: &cancellables)
        // A turn becomes stuck by time alone, with no event to say so.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshQueue() }
            .store(in: &cancellables)
        refreshQueue()
    }

    func refreshQueue() {
        queue.refresh(sessions: Array(store.state.sessions.values), suggestions: lampMaster?.snapshot.open ?? [])
    }
}
