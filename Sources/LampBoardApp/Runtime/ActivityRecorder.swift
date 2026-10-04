import Foundation
import LampBoardCore

/// What each session has been doing, for the Plancia's Activity and Cost tabs
/// (UX §5): the mod's tools and costs, the hooks' turn ends, per session.
///
/// In memory only, and bounded: a view of now, not a record, for the sessions
/// seen most recently.
@MainActor
final class ActivityRecorder: ObservableObject {

    @Published private(set) var logs: [String: SessionActivity] = [:]

    /// Sessions kept: more than a day of Marco's scale, and a bound.
    static let sessionsKept = 64

    func record(_ report: ModReport, at date: Date) {
        update(report.session) { $0.record(report, at: date) }
    }

    func turnEnded(sessionId: String, at date: Date) {
        update(sessionId) { $0.turnEnded(at: date) }
    }

    private func update(_ id: String, _ change: (inout SessionActivity) -> Void) {
        var log = logs[id] ?? SessionActivity()
        change(&log)
        logs[id] = log
        guard logs.count > Self.sessionsKept else { return }
        // The one heard from longest ago goes.
        let oldest = logs.min { ($0.value.entries.last?.at ?? .distantPast) < ($1.value.entries.last?.at ?? .distantPast) }
        if let oldest { logs[oldest.key] = nil }
    }
}
