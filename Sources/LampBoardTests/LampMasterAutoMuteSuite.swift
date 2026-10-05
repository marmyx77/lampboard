import LampBoardCore
import Foundation
import TestKit

/// A kind of suggestion that stays under a fifth accepted for two weeks
/// switches itself off (D5): a local count, no token, and said where the
/// kinds are listed.
enum LampMasterAutoMuteSuite {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    static func shown(_ kind: LampMasterAdvice.Suggestion.Kind, daysAgo: Double, _ outcome: LampMasterShown.Outcome?) -> LampMasterShown {
        LampMasterShown(
            id: UUID().uuidString, at: now.addingTimeInterval(-daysAgo * day),
            suggestion: LampMasterAdvice.Suggestion(kind: kind, sessions: ["aaaaaaaa"], text: "t", evidence: "e",
                                                    action: .init(kind: .none), confidence: 0.9, key: "k"),
            outcome: outcome
        )
    }

    /// Twelve reactions over the last two weeks, `accepted` of them taken up,
    /// and one shown three weeks ago so the kind has been around that long.
    static func history(_ kind: LampMasterAdvice.Suggestion.Kind, accepted: Int) -> [LampMasterShown] {
        [shown(kind, daysAgo: 21, .ignored)]
            + (0..<12).map { shown(kind, daysAgo: Double($0), $0 < accepted ? .accepted : .ignored) }
    }

    static let suite = TestSuite("LampMaster: kinds that switch themselves off", [

        TestCase("Under a fifth accepted over two weeks, with enough to judge: off, and why") { t in
            let verdicts = LampMasterAutoMute.verdicts(history(.stalled, accepted: 1) + history(.cross, accepted: 6),
                                                       muted: [], now: now)
            t.expectEqual(verdicts.map(\.kind), [.stalled], "1 of 12 is under a fifth; 6 of 12 is not")
            t.expectEqual(verdicts.first?.reason, "1 of 12 accepted in two weeks")
        },

        TestCase("Too few reactions, or not two weeks of them: nothing switched off") { t in
            let few = [shown(.overlap, daysAgo: 20, .ignored)] + (0..<5).map { shown(.overlap, daysAgo: Double($0), .ignored) }
            t.expectEqual(LampMasterAutoMute.verdicts(few, muted: [], now: now).count, 0, "five is too few to judge")
            let young = (0..<12).map { shown(.closable, daysAgo: Double($0) / 2, .ignored) }
            t.expectEqual(LampMasterAutoMute.verdicts(young, muted: [], now: now).count, 0, "six days of history is not two weeks")
        },

        TestCase("What counts: taken up against ignored, wrong or let expire; nothing still open or superseded") { t in
            let mixed = [shown(.precedent, daysAgo: 20, .ignored)]
                + (0..<4).map { shown(.precedent, daysAgo: Double($0), .wrong) }
                + (0..<4).map { shown(.precedent, daysAgo: Double($0), .expired) }
                + (0..<4).map { shown(.precedent, daysAgo: Double($0), .ignored) }
                + (0..<9).map { shown(.precedent, daysAgo: Double($0), nil) }
                + (0..<9).map { shown(.precedent, daysAgo: Double($0), .superseded) }
            t.expectEqual(LampMasterAutoMute.verdicts(mixed, muted: [], now: now).first?.reason, "0 of 12 accepted in two weeks")
        },

        TestCase("A kind already off is left alone; one suggested again counts from then") { t in
            t.expectEqual(LampMasterAutoMute.verdicts(history(.stalled, accepted: 0), muted: [.stalled], now: now).count, 0)
            let again = LampMasterAutoMute.verdicts(history(.stalled, accepted: 0), muted: [],
                                                     since: [.stalled: now.addingTimeInterval(-3 * day)], now: now)
            t.expectEqual(again.count, 0, "three days since it was asked back: not two weeks yet")
        },
    ])
}
