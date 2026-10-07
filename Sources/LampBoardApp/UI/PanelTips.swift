import Combine
import Foundation
import LampBoardCore

/// The tip shown at the top of the panel, if any (U5).
@MainActor
final class TipStage: ObservableObject {
    @Published private(set) var current: Tips.Tip?
    /// The tip came or went: the window is remeasured.
    var onChange: () -> Void = {}

    func show(_ tip: Tips.Tip, preferences: Preferences) {
        guard current == nil else { return }
        var shown = preferences.tipsShown
        shown[tip.rawValue] = Date()
        preferences.tipsShown = shown
        current = tip
        onChange()
    }

    func dismiss() {
        guard current != nil else { return }
        current = nil
        onChange()
    }
}

/// When a tip is due (U5): the first time something is on the panel — a session
/// asking, a turn stopping, four fifths of the window used, six rows, a fold —
/// one line says what it means, once, one a day at most, and goes by itself when
/// its thing is over.
/// Asked when the state changes and every half minute; never in the demo, whose
/// sessions are invented.
extension PanelController {

    func wireTips() {
        // Remeasured, not rebuilt: rebuilding would take the bar's focus from a
        // person typing in it. The band observes the stage itself.
        tips.onChange = { [weak self] in guard let self else { return }; self.resizeToFit(self.store.state) }
        guard TrialStage.mode == nil else { return }
        store.$state
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.offerTip() }
            .store(in: &cancellables)
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.offerTip() }
            .store(in: &cancellables)
    }

    func offerTip(now: Date = Date()) {
        let statuses = store.state.sessions.values.map(\.status)
        let rendering = ColumnLayout.render(store.state, options: columnOptions, now: now)
        let usage = allowance.reports.compactMap { AllowanceLines.shown(in: $0)?.percent }.max()
        let facts = Tips.Facts(
            stopped: statuses.contains(.failed), needsYou: statuses.contains(.awaiting), usagePercent: usage,
            rowCount: rendering.rows.count, resting: rendering.resting != nil
        )
        // A tip whose thing is over goes by itself: «a session waits» after it
        // was answered would be the stale line this panel stopped showing (U2).
        if let current = tips.current {
            if !Tips.holds(current, facts) { tips.dismiss() }
            return
        }
        // Spent only where it can be read: the panel on screen, nobody typing.
        guard panel.isVisible, !bar.isEditing,
              let tip = Tips.next(facts, shown: preferences.tipsShown, now: now) else { return }
        tips.show(tip, preferences: preferences)
    }
}
