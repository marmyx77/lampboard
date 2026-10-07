import Foundation

/// What happened while the person was away (§5.8, A1), kept from the moment they
/// left and said in one line when they come back. Counted as it happens, not read
/// off the column at the end: a session that answered and was closed while
/// nobody was there still answered.
public struct AwayLedger: Sendable, Equatable {
    public let since: Date
    /// Turns that ended with an answer, per session.
    public private(set) var answers: [String: Int] = [:]
    /// Sessions whose turn failed.
    public private(set) var failed: Set<String> = []
    private var lastStatus: [String: SessionStatus]
    private let costAtStart: [String: Double]
    private var lastCost: [String: Double]

    public init(since: Date, state: TrafficLightState) {
        self.since = since
        lastStatus = state.sessions.mapValues(\.status)
        costAtStart = state.sessions.compactMapValues(\.costUSD)
        lastCost = costAtStart
    }

    public mutating func observe(_ state: TrafficLightState) {
        for (id, session) in state.sessions {
            let before = lastStatus[id]
            if session.status == .ready, before != .ready { answers[id, default: 0] += 1 }
            if session.status == .failed, before != .failed { failed.insert(id) }
            lastStatus[id] = session.status
            if let cost = session.costUSD { lastCost[id] = cost }
        }
    }

    /// "While you were away (1h 20m): 2 earlier answers (api, docs), 1 earlier
    /// failure (billing), $2.10 spent." The sessions are named by `name`.
    ///
    /// Only what the rows no longer show (U2). An answer still green on its row,
    /// a failure still red, a session still amber: the column says those, and a
    /// line that repeated them was the «notification of the notification» the
    /// 1.1 review found. And nothing at all when there is nothing else to say —
    /// never «nothing happened», which reads as a fault.
    public func summary(now: Date, state: TrafficLightState, name: (String) -> String) -> String? {
        let gone = now.timeIntervalSince(since)
        let head = "While you were away (\(gone < 60 ? "under a minute" : WeekSummary.duration(gone)))"
        // A session still showing an answer shows one of them: the rest are earlier.
        let earlier = answers.compactMap { id, count -> (String, Int)? in
            let shown = state.sessions[id]?.status == .ready ? 1 : 0
            return count > shown ? (id, count - shown) : nil
        }.sorted { $0.0 < $1.0 }
        let earlierFailures = failed.filter { state.sessions[$0]?.status != .failed }.sorted()
        let spent = lastCost.reduce(0.0) { $0 + max(0, $1.value - (costAtStart[$1.key] ?? 0)) }
        var parts: [String] = []
        let total = earlier.reduce(0) { $0 + $1.1 }
        if total > 0 {
            parts.append("\(total) earlier answer\(total == 1 ? "" : "s") (\(earlier.map { name($0.0) }.joined(separator: ", ")))")
        }
        if !earlierFailures.isEmpty {
            let count = earlierFailures.count
            parts.append("\(count) earlier failure\(count == 1 ? "" : "s") (\(earlierFailures.map(name).joined(separator: ", ")))")
        }
        if spent >= 0.01 { parts.append(String(format: "$%.2f spent", spent)) }
        return parts.isEmpty ? nil : head + ": " + parts.joined(separator: ", ") + "."
    }
}
