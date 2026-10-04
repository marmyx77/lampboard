import LampBoardCore
import Foundation
import TestKit

/// The quick round (D72): a look now, with Sonnet, when a session
/// starts repeating a failure or stops moving, rather than at the hour.
enum LampMasterQuickSuite {

    typealias F = LampMasterFixtures
    typealias Q = LampMasterQuick

    static func due(
        _ urgent: Set<String>, seen: Set<String> = [], lastRun: Double? = 0, today: Int = 0, at minutes: Double
    ) -> Bool {
        Q.due(urgent: urgent, seen: seen, lastRun: lastRun.map(F.at), quickToday: today, now: F.at(minutes))
    }

    static func round(_ trigger: LampMasterSchedule.Trigger, _ outcome: LampMasterRound.Outcome, at minutes: Double) -> LampMasterRound {
        LampMasterRound(at: F.at(minutes), trigger: trigger, outcome: outcome)
    }

    static let suite = TestSuite("LampMaster's quick round", [

        TestCase("Only a repeated failure and a stuck turn are urgent, each a key of its own") { t in
            let keys = Q.urgent([
                "aaaaaaaa": [.repeatedFailure(fingerprint: "npm err! missing script"), .contextHigh, .waitingOnYou],
                "bbbbbbbb": [.stuck, .sameFiles(with: "aaaaaaaa")],
                "cccccccc": [.finished, .sameBranch(with: "bbbbbbbb")],
            ])
            t.expectEqual(keys, ["aaaaaaaa failure npm err! missing script", "bbbbbbbb stuck"])
        },

        TestCase("A quick round needs a pair the last round did not see") { t in
            t.expect(!due([], at: 60), "nothing urgent")
            t.expect(!due(["a stuck"], seen: ["a stuck"], at: 60), "already looked at")
            t.expect(due(["a stuck", "b stuck"], seen: ["a stuck"], at: 60), "a second session stuck")
            t.expect(due(["a stuck"], seen: ["b stuck"], at: 60), "gone and another come")
            t.expect(due(["a stuck"], lastRun: nil, at: 0), "never ran")
        },

        TestCase("Ten minutes after any round, and six a day") { t in
            t.expect(!due(["a stuck"], at: 9), "within ten minutes of the last round")
            t.expect(due(["a stuck"], at: 10), "ten minutes on")
            t.expect(!due(["a stuck"], today: Q.perDay, at: 60), "the day's six are spent")
            t.expect(due(["a stuck"], today: Q.perDay - 1, at: 60), "one left")
        },

        TestCase("Today's quick rounds are those that reached claude today") { t in
            let rounds = [
                round(.quick, .ran, at: -24 * 60),
                round(.quick, .ran, at: 10), round(.quick, .failed, at: 30), round(.quick, .skipped, at: 40),
                round(.timer, .ran, at: 50),
            ]
            t.expectEqual(Q.count(on: F.at(60), in: rounds), 2, "yesterday, skips and the timer do not count")
        },

        TestCase("A round keeps the pairs it saw, and an old record reads without them") { t in
            let kept = LampMasterRound(at: F.at(0), trigger: .quick, outcome: .ran, model: Q.model, urgent: ["a stuck"])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = (try? encoder.encode(kept)) ?? Data()
            t.expectEqual((try? decoder.decode(LampMasterRound.self, from: data))?.urgent, ["a stuck"])
            let old = #"{"at":"2026-10-04T10:00:00Z","trigger":"timer","outcome":"ran","tokens":0,"sessions":1,"proposed":0,"rejected":{},"shown":0}"#
            let read = try? decoder.decode(LampMasterRound.self, from: Data(old.utf8))
            t.expectNotNil(read, "a round written before quick rounds")
            t.expectNil(read?.urgent)
        },

        TestCase("The quick round waits like the others, and runs Sonnet") { t in
            let decision = LampMasterSchedule.decide(
                trigger: .quick, enabled: false, interval: LampMasterSchedule.defaultInterval, lastRun: nil,
                lastDigest: nil, digest: "d", sessionCount: 2, tokensToday: 0, now: F.at(0))
            t.expectEqual(decision, .skip(.off), "switched off is off")
            let capped = LampMasterSchedule.decide(
                trigger: .quick, enabled: true, interval: LampMasterSchedule.defaultInterval, lastRun: nil,
                lastDigest: nil, digest: "d", sessionCount: 2, tokensToday: LampMasterSchedule.dailyTokenCap, now: F.at(0))
            t.expectEqual(capped, .skip(.dailyCap), "the day's ceiling is shared")
            t.expectEqual(Q.model, "sonnet", "measured quicker than Haiku")
        },
    ])
}
