import Combine
import Foundation
import LampBoardCore

/// "I'm away" (§5.8, A1). Away is said from the panel's menu, or by the screen
/// staying locked for `awayAfterLock`. While away, notifications wait and a
/// ledger counts what happens; on return one line says it — as a notification,
/// and in the panel until it is clicked away.
@MainActor
final class AwayMonitor {
    private let store: StateStore
    private let preferences: Preferences
    private var ledger: AwayLedger?
    private var lockedSince: Date?
    private var timer: Timer?
    private var watching: AnyCancellable?
    /// Said on return, for the notification and for the panel to make room.
    var onBack: (String) -> Void = { _ in }

    init(store: StateStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    var isAway: Bool { ledger != nil }

    func start() {
        watching = store.$state.receive(on: RunLoop.main).sink { [weak self] state in self?.ledger?.observe(state) }
        let timer = Timer.scheduledTimer(withTimeInterval: AppConfig.presencePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update()
    }

    /// The menu's switch.
    func toggle() {
        preferences.awayManual.toggle()
        update()
    }

    func update(now: Date = Date()) {
        if PresenceFile.isScreenLocked { lockedSince = lockedSince ?? now } else { lockedSince = nil }
        let away = preferences.awayManual || lockedSince.map { now.timeIntervalSince($0) >= AppConfig.awayAfterLock } ?? false
        if away, ledger == nil {
            // Gone: from now on what happens is counted, from the moment the lock began.
            ledger = AwayLedger(since: lockedSince ?? now, state: store.state)
            store.awayNote = nil
        } else if !away, let gone = ledger {
            ledger = nil
            let names = { [store, preferences] (id: String) -> String in
                guard let session = store.state.sessions[id] else { return String(id.prefix(8)) }
                return RowActivity.flat(RowNames.name(of: session.workspace.key, in: preferences.rowNames) ?? session.displayName)
            }
            let line = gone.summary(now: now, state: store.state, name: names)
            store.awayNote = line
            onBack(line)
        }
    }
}
