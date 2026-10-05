import LampBoardCore
import Foundation
import TestKit

/// LampMaster's window beside its cards (D5): today, the last frame, the cost.
enum LampMasterSheetsSuite {

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    static let now = Date(timeIntervalSince1970: 1_800_000_000)  // 15 January 2027, 08:00 UTC

    static func shown(_ id: String, _ kind: LampMasterAdvice.Suggestion.Kind, hoursAgo: Double, _ outcome: LampMasterShown.Outcome?) -> LampMasterShown {
        LampMasterShown(id: id, at: now.addingTimeInterval(-hoursAgo * 3_600),
                        suggestion: LampMasterAdvice.Suggestion(kind: kind, sessions: ["aaaaaaaa"], text: "text \(id)", evidence: "e",
                                                                action: .init(kind: .none), confidence: 0.9, key: id),
                        outcome: outcome)
    }

    static let suite = TestSuite("LampMaster: the window's sheets", [

        TestCase("Today: the day's suggestions, the newest first, with what became of them") { t in
            let lines = LampMasterSheets.today([shown("a", .cross, hoursAgo: 1, .accepted), shown("b", .stalled, hoursAgo: 3, nil),
                                                shown("c", .overlap, hoursAgo: 30, .ignored)], now: now, calendar: utc)
            t.expectEqual(lines.map(\.id), ["a", "b"], "yesterday's is not today's")
            t.expectEqual(lines.map(\.outcome), ["accepted", "open"])
        },

        TestCase("Frame: who was in the last one, with signals, precedents and the allowance") { t in
            let frame = #"{"now":"x","quota":[{"account":"design@example.com","used":0.62,"runsOutBeforeReset":true}],"#
                + #""sessions":[{"id":"aaaaaaaa","project":"events","host":"mac","state":"idle","signals":["stuck in a turn"]},"#
                + #"{"id":"bbbbbbbb","project":"api","host":"node","state":"working","signals":[]}],"#
                + #""precedents":[{"session":"aaaaaaaa","error":"e","found":[{"id":"1"},{"id":"2"}]}],"recent":[],"muted":[],"notebook":""}"#
            let sheet = LampMasterSheets.frame(frame + "\n{\"advice\":1}\n")
            t.expectEqual(sheet?.sessions.map(\.project), ["events", "api"])
            t.expectEqual(sheet?.sessions.first?.signals, ["stuck in a turn"])
            t.expectEqual(sheet?.sessions.first?.precedents, 2)
            t.expectEqual(sheet?.sessions.last?.host, "node")
            t.expectEqual(sheet?.quota, ["design@example.com: 62 % used, runs out before the reset"])
            t.expectNil(LampMasterSheets.frame("not a frame"))
        },

        TestCase("Cost: today's rounds and spending, the last runs, each kind with its acceptance and state") { t in
            let rounds = [
                LampMasterRound(at: now.addingTimeInterval(-3_600), trigger: .timer, outcome: .ran, model: "opus", tokens: 6_000, costUSD: 0.08),
                LampMasterRound(at: now.addingTimeInterval(-1_800), trigger: .timer, outcome: .skipped, skip: .unchanged),
                LampMasterRound(at: now.addingTimeInterval(-86_400 * 2), trigger: .timer, outcome: .failed),
            ]
            let sheet = LampMasterSheets.cost(rounds: rounds, shown: [shown("a", .cross, hoursAgo: 1, .accepted),
                                                                      shown("b", .cross, hoursAgo: 2, .ignored)],
                                              muted: [.stalled], autoMuted: [.stalled: "1 of 12 accepted in two weeks"],
                                              now: now, calendar: utc)
            t.expectEqual([sheet.ran, sheet.skipped, sheet.failed], [1, 1, 0], "today only")
            t.expectEqual(sheet.tokensToday, 6_000)
            t.expectEqual(sheet.costToday, 0.08)
            t.expectEqual(sheet.lastRuns.count, 2, "skips are not runs; the failed one of two days ago is")
            let cross = sheet.kinds.first { $0.kind == .cross }, stalled = sheet.kinds.first { $0.kind == .stalled }
            t.expectEqual(cross?.accepted, 1)
            t.expectEqual(cross?.counted, 2)
            t.expectEqual(stalled?.on, false)
            t.expectEqual(stalled?.switchedOffBecause, "1 of 12 accepted in two weeks")
        },
    ])
}
