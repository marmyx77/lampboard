import Foundation
import LampBoardCore

/// The three sample rows while they are in the panel (U4): when they came, which
/// ones were clicked, and a tick each second so their colours play out.
///
/// The rows themselves are `Samples`'s. They are added to what the column draws
/// and to what sizes the window, never to the store: nothing that notifies,
/// counts, searches or reviews sessions ever sees them.
@MainActor
final class SampleStage: ObservableObject {
    @Published private(set) var since: Date?
    @Published private(set) var seen: Set<String> = []
    @Published private(set) var tick = 0
    /// The rows changed: the window is remeasured.
    var onChange: () -> Void = {}
    private var timer: Timer?

    var isOn: Bool { since != nil }

    func sessions(now: Date = Date()) -> [SessionState] {
        guard let since else { return [] }
        return Samples.sessions(since: since, now: now, seen: seen)
    }

    func start() {
        since = Date()
        seen = []
        tick = 0
        timer?.invalidate()
        // Long enough for every colour to have shown: api asks from sixteen
        // seconds on, and stays asking until it is clicked or the samples go.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                if self.tick > 30 { self.timer?.invalidate(); self.timer = nil }
            }
        }
        onChange()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        since = nil
        seen = []
        onChange()
    }

    /// A sample was clicked: it rests, the way a read answer does.
    func markSeen(_ id: String) {
        seen.insert(id)
        onChange()
    }
}
