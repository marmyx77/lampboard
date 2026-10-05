import Foundation

/// A kind of suggestion that stays under a fifth accepted for two weeks
/// switches itself off (D5, the plan's rule against noise): a count of what
/// the person did with the cards, kept on this Mac, no token. One wrong
/// suggestion spoils trust more than a missing one; a kind the person keeps
/// passing over is costing them reading time for nothing.
public enum LampMasterAutoMute {

    public static let window: TimeInterval = 14 * 24 * 60 * 60
    /// Below this share taken up, the kind is off.
    public static let below = 0.2
    /// Fewer reactions than this are not enough to judge.
    public static let minimum = 10

    public struct Verdict: Sendable, Equatable {
        public let kind: LampMasterAdvice.Suggestion.Kind
        public let accepted: Int
        public let counted: Int

        /// Said where the kinds are listed, beside "Suggest again".
        public var reason: String { "\(accepted) of \(counted) accepted in two weeks" }
    }

    /// What counts: a card taken up, against one ignored, marked wrong or left
    /// to expire. One still open, or settled by its sessions leaving, says nothing.
    static let judged: Set<LampMasterShown.Outcome> = [.accepted, .ignored, .wrong, .expired]

    /// The kinds to switch off now. A kind already off is left alone; one asked
    /// back with "Suggest again" counts only from then, or its old record would
    /// switch it off again at the next round.
    public static func verdicts(
        _ shown: [LampMasterShown], muted: Set<LampMasterAdvice.Suggestion.Kind>,
        since: [LampMasterAdvice.Suggestion.Kind: Date] = [:], now: Date
    ) -> [Verdict] {
        let start = now.addingTimeInterval(-window)
        return LampMasterAdvice.Suggestion.Kind.allCases.compactMap { kind -> Verdict? in
            guard !muted.contains(kind) else { return nil }
            let from = since[kind] ?? .distantPast
            let history = shown.filter { $0.suggestion.kind == kind && $0.at >= from }
            // Two weeks of it: a bad first week is not yet a pattern.
            guard let first = history.map(\.at).min(), first <= start else { return nil }
            let recent = history.filter { $0.at >= start && $0.outcome.map(judged.contains) == true }
            guard recent.count >= minimum else { return nil }
            let accepted = recent.filter { $0.outcome == .accepted }.count
            guard Double(accepted) / Double(recent.count) < below else { return nil }
            return Verdict(kind: kind, accepted: accepted, counted: recent.count)
        }
    }
}
