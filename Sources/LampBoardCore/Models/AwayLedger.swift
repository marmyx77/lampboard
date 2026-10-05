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

    /// "While you were away (1h 20m): 3 answers (api, docs), 1 waiting for you
    /// (api), 1 failed (billing), $2.10 spent." The sessions are named by `name`.
    public func summary(now: Date, state: TrafficLightState, name: (String) -> String) -> String {
        let gone = now.timeIntervalSince(since)
        let head = "While you were away (\(gone < 60 ? "under a minute" : WeekSummary.duration(gone)))"
        let answered = answers.keys.sorted()
        let waiting = state.sessions.values.filter { $0.status == .awaiting }.map(\.id).sorted()
        let spent = lastCost.reduce(0.0) { $0 + max(0, $1.value - (costAtStart[$1.key] ?? 0)) }
        var parts: [String] = []
        let total = answers.values.reduce(0, +)
        if total > 0 { parts.append("\(total) answer\(total == 1 ? "" : "s") (\(answered.map(name).joined(separator: ", ")))") }
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting for you (\(waiting.map(name).joined(separator: ", ")))") }
        if !failed.isEmpty { parts.append("\(failed.count) failed (\(failed.sorted().map(name).joined(separator: ", ")))") }
        if spent >= 0.01 { parts.append(String(format: "$%.2f spent", spent)) }
        return parts.isEmpty ? head + ": nothing happened." : head + ": " + parts.joined(separator: ", ") + "."
    }
}
