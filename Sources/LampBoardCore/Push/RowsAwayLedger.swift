import Foundation

/// «While you were away» for a source that speaks in `v1` rows (§5.8, A1): what
/// happened to one device's person since that device was last in their hand,
/// counted as it happened, said once when the app comes back (`hello.away`).
///
/// The Mac's `AwayLedger` counts over its own state; this one over the rows a
/// source sends, with the same sentence. A row read from the files has no
/// answer to read (green comes with the hooks, W5), so a turn that worked and
/// came to rest counts as an answer here.
public struct RowsAwayLedger: Codable, Equatable, Sendable {
    public let since: Date
    public private(set) var answers: [String: Int] = [:]
    public private(set) var failed: Set<String> = []
    public private(set) var names: [String: String] = [:]
    private var last: [String: String]

    public init(since: Date, rows: [V1Row]) {
        self.since = since
        last = Dictionary(rows.map { ($0.id, $0.session.status) }, uniquingKeysWith: { first, _ in first })
    }

    public mutating func observe(_ rows: [V1Row]) {
        for row in rows {
            let before = last[row.id]
            let now = row.session.status
            if let before, before != now {
                if now == SessionStatus.ready.rawValue || PushPlanner.finishedATurn(from: before, to: now) {
                    answers[row.id, default: 0] += 1
                    names[row.id] = PushPlanner.name(of: row)
                }
                if now == SessionStatus.failed.rawValue {
                    failed.insert(row.id)
                    names[row.id] = PushPlanner.name(of: row)
                }
            }
            last[row.id] = now
        }
    }

    /// The line, or `nil` when there is nothing the column does not already say.
    public func summary(now: Date, rows: [V1Row]) -> String? {
        let current = Dictionary(rows.map { ($0.id, $0.session.status) }, uniquingKeysWith: { first, _ in first })
        let earlier = answers.compactMap { id, count -> (String, Int)? in
            let shown = current[id] == SessionStatus.ready.rawValue ? 1 : 0
            return count > shown ? (id, count - shown) : nil
        }.sorted { $0.0 < $1.0 }
        let earlierFailures = failed.filter { current[$0] != SessionStatus.failed.rawValue }.sorted()
        var parts: [String] = []
        let total = earlier.reduce(0) { $0 + $1.1 }
        if total > 0 {
            let who = earlier.map { names[$0.0] ?? $0.0 }.joined(separator: ", ")
            parts.append("\(total) turn\(total == 1 ? "" : "s") finished (\(who))")
        }
        if !earlierFailures.isEmpty {
            let count = earlierFailures.count
            parts.append("\(count) earlier failure\(count == 1 ? "" : "s") (\(earlierFailures.map { names[$0] ?? $0 }.joined(separator: ", ")))")
        }
        guard !parts.isEmpty else { return nil }
        let gone = now.timeIntervalSince(since)
        return "While you were away (\(gone < 60 ? "under a minute" : WeekSummary.duration(gone))): " + parts.joined(separator: ", ") + "."
    }
}
