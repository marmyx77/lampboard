import Foundation

/// LampMaster's test bench (D5, the plan's §8.3): to change the prompt, the model
/// or a threshold, the rounds' saved frames are replayed with the new version and
/// its suggestions set against the old ones and against what the person did with
/// them. A suggestion accepted then and missing now is a regression; one ignored
/// then and gone now is an improvement. Run by hand on this Mac, never in CI: it
/// spends a round's tokens per frame, and the frames never leave the Mac.
public enum LampMasterBench {

    /// One saved round: the frame it was given and the answer it got, as
    /// `LampMasterFiles` keeps them — the frame on the first line, the answer after.
    public struct Saved: Sendable, Equatable {
        public let at: Date
        public let frame: String
        public let output: String
    }

    public static func saved(_ text: String, at: Date) -> Saved? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let output = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return Saved(at: at, frame: String(parts[0]), output: output)
    }

    public struct Comparison: Sendable, Equatable {
        public let kept: [LampMasterAdvice.Suggestion]
        public let lost: [LampMasterAdvice.Suggestion]
        public let added: [LampMasterAdvice.Suggestion]
        /// Accepted then, missing now.
        public let regressions: Int
        /// Ignored, marked wrong or let expire then, gone now.
        public let gains: Int
        let outcomes: [String: LampMasterShown.Outcome]
    }

    /// Matched by key, the round's own name for a suggestion's subject.
    public static func compare(
        old: [LampMasterAdvice.Suggestion], new: [LampMasterAdvice.Suggestion], outcomes: [String: LampMasterShown.Outcome]
    ) -> Comparison {
        let newKeys = Set(new.map(\.key)), oldKeys = Set(old.map(\.key))
        let lost = old.filter { !newKeys.contains($0.key) }.sorted { $0.key < $1.key }
        let unwanted: Set<LampMasterShown.Outcome> = [.ignored, .wrong, .expired]
        return Comparison(
            kept: old.filter { newKeys.contains($0.key) }.sorted { $0.key < $1.key },
            lost: lost,
            added: new.filter { !oldKeys.contains($0.key) }.sorted { $0.key < $1.key },
            regressions: lost.filter { outcomes[$0.key] == .accepted }.count,
            gains: lost.filter { outcomes[$0.key].map(unwanted.contains) == true }.count,
            outcomes: outcomes
        )
    }

    /// What a person reads to decide: the totals, then each round, the
    /// regressions first.
    public static func report(_ rounds: [(at: Date, comparison: Comparison)], model: String) -> String {
        let regressions = rounds.reduce(0) { $0 + $1.comparison.regressions }
        let gains = rounds.reduce(0) { $0 + $1.comparison.gains }
        let added = rounds.reduce(0) { $0 + $1.comparison.added.count }
        let plural = { (count: Int, noun: String) in "\(count) \(noun)\(count == 1 ? "" : "s")" }
        var lines = ["Bench: \(plural(rounds.count, "round")) replayed with \(model). "
            + "\(plural(regressions, "accepted suggestion")) lost, \(gains) ignored gone, \(added) new."]
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        for (at, comparison) in rounds {
            lines.append("")
            lines.append(stamp.string(from: at) + " · kept \(comparison.kept.count), lost \(comparison.lost.count), new \(comparison.added.count)")
            let lost = comparison.lost.sorted { (comparison.outcomes[$0.key] == .accepted ? 0 : 1) < (comparison.outcomes[$1.key] == .accepted ? 0 : 1) }
            for suggestion in lost {
                let outcome = comparison.outcomes[suggestion.key].map { $0.rawValue } ?? "no reaction"
                lines.append("  lost (\(outcome)): " + LampMasterLookup.clean(suggestion.text, to: 120))
            }
            for suggestion in comparison.added {
                lines.append("  new: " + LampMasterLookup.clean(suggestion.text, to: 120))
            }
        }
        return lines.joined(separator: "\n")
    }
}
