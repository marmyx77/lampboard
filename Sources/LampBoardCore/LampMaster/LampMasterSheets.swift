import Foundation

/// What LampMaster's window shows beside its cards (D5): today's suggestions
/// and what became of them, the frame the last round was given, and what the
/// rounds cost. All from the files LampMaster already keeps; nothing new is
/// recorded and nothing is spent to draw them.
public enum LampMasterSheets {

    // MARK: - Today

    public struct TodayLine: Sendable, Equatable, Identifiable {
        public let id: String
        public let at: Date
        public let kind: LampMasterAdvice.Suggestion.Kind
        public let text: String
        /// "open", or what became of it.
        public let outcome: String
    }

    /// Today's suggestions, the newest first.
    public static func today(_ shown: [LampMasterShown], now: Date, calendar: Calendar = .current) -> [TodayLine] {
        shown.filter { calendar.isDate($0.at, inSameDayAs: now) }
            .sorted { $0.at > $1.at }
            .map { TodayLine(id: $0.id, at: $0.at, kind: $0.suggestion.kind, text: $0.suggestion.text,
                             outcome: $0.outcome?.rawValue ?? "open") }
    }

    // MARK: - Frame

    public struct FrameLine: Sendable, Equatable, Identifiable {
        public let id: String
        public let project: String
        public let host: String
        public let state: String
        public let signals: [String]
        public let precedents: Int
    }

    public struct FrameSheet: Sendable, Equatable {
        public let sessions: [FrameLine]
        public let quota: [String]
        public let estimatedTokens: Int
    }

    /// The frame a saved round file begins with — its first line — read back
    /// for the person: who was in it, with which signals and how many precedents.
    public static func frame(_ saved: String) -> FrameSheet? {
        guard let first = saved.split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]]
        else { return nil }
        let precedents = (object["precedents"] as? [[String: Any]] ?? []).reduce(into: [String: Int]()) { counts, entry in
            if let session = entry["session"] as? String { counts[session, default: 0] += (entry["found"] as? [Any])?.count ?? 0 }
        }
        let lines = sessions.compactMap { session -> FrameLine? in
            guard let id = session["id"] as? String else { return nil }
            return FrameLine(id: id, project: session["project"] as? String ?? "?", host: session["host"] as? String ?? "mac",
                             state: session["state"] as? String ?? "?", signals: session["signals"] as? [String] ?? [],
                             precedents: precedents[id] ?? 0)
        }
        let quota = (object["quota"] as? [[String: Any]] ?? []).compactMap { line -> String? in
            guard let account = line["account"] as? String, let used = line["used"] as? Double else { return nil }
            let tight = line["runsOutBeforeReset"] as? Bool == true ? ", runs out before the reset" : ""
            return "\(account): \(Int((used * 100).rounded())) % used\(tight)"
        }
        return FrameSheet(sessions: lines, quota: quota, estimatedTokens: Int((Double(first.count) / 3.5).rounded(.up)))
    }

    // MARK: - Cost

    public struct KindLine: Sendable, Equatable, Identifiable {
        public var id: String { kind.rawValue }
        public let kind: LampMasterAdvice.Suggestion.Kind
        public let on: Bool
        public let accepted: Int
        public let counted: Int
        /// Why it switched itself off, when it did (D95).
        public let switchedOffBecause: String?
    }

    public struct CostSheet: Sendable, Equatable {
        public let ran: Int
        public let skipped: Int
        public let failed: Int
        public let tokensToday: Int
        public let costToday: Double
        public let cap: Int
        /// The last rounds that reached `claude`, the newest first.
        public let lastRuns: [LampMasterRound]
        public let kinds: [KindLine]
    }

    public static func cost(
        rounds: [LampMasterRound], shown: [LampMasterShown], muted: Set<LampMasterAdvice.Suggestion.Kind>,
        autoMuted: [LampMasterAdvice.Suggestion.Kind: String], now: Date, calendar: Calendar = .current
    ) -> CostSheet {
        let today = rounds.filter { calendar.isDate($0.at, inSameDayAs: now) }
        let start = now.addingTimeInterval(-LampMasterAutoMute.window)
        let kinds = LampMasterAdvice.Suggestion.Kind.allCases.map { kind -> KindLine in
            let judged = shown.filter {
                $0.suggestion.kind == kind && $0.at >= start && $0.outcome.map(LampMasterAutoMute.judged.contains) == true
            }
            return KindLine(kind: kind, on: !muted.contains(kind), accepted: judged.filter { $0.outcome == .accepted }.count,
                            counted: judged.count, switchedOffBecause: autoMuted[kind])
        }
        return CostSheet(
            ran: today.filter { $0.outcome == .ran }.count, skipped: today.filter { $0.outcome == .skipped }.count,
            failed: today.filter { $0.outcome == .failed }.count,
            tokensToday: today.reduce(0) { $0 + $1.tokens }, costToday: today.compactMap(\.costUSD).reduce(0, +),
            cap: LampMasterSchedule.dailyTokenCap,
            lastRuns: Array(rounds.filter { $0.outcome != .skipped }.sorted { $0.at > $1.at }.prefix(10)),
            kinds: kinds
        )
    }
}
