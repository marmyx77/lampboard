import LampBoardCore
import Foundation
import TestKit

/// The allowance in the round's frame, and the round giving way to it (D4):
/// a forecast at the pace so far, no history needed, no token spent.
enum LampMasterQuotaSuite {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func limit(_ span: AccountLimits.Limit.Span, _ percent: Int, resetIn minutes: Double?) -> AccountLimits.Limit {
        AccountLimits.Limit(span: span, percent: percent, resetsAt: minutes.map { now.addingTimeInterval($0 * 60) })
    }

    static func report(_ name: String, _ limits: [AccountLimits.Limit]) -> AllowanceReport {
        AllowanceReport(account: nil, machine: name, limits: AccountLimits(limits: limits, readAt: now))
    }

    static let suite = TestSuite("LampMaster: the allowance", [

        TestCase("At the pace so far: 60 % of five hours in two runs out before the reset; 30 % does not") { t in
            t.expect(LampMasterQuota.runsOut(limit(.session, 60, resetIn: 180), now: now), "60 % in 2 h → 150 % at 5 h")
            t.expect(!LampMasterQuota.runsOut(limit(.session, 30, resetIn: 180), now: now), "30 % in 2 h → 75 %")
            t.expect(LampMasterQuota.runsOut(limit(.week, 100, resetIn: 60), now: now), "already full")
        },

        TestCase("Too early in a window to say, or no reset known: no forecast") { t in
            t.expect(!LampMasterQuota.runsOut(limit(.session, 10, resetIn: 290), now: now), "ten minutes in: too early")
            t.expect(!LampMasterQuota.runsOut(limit(.session, 90, resetIn: nil), now: now), "no reset, no pace")
        },

        TestCase("One line per account in the frame: the window most at risk") { t in
            let quota = LampMasterQuota.frame([
                report("this Mac", [limit(.session, 20, resetIn: 200), limit(.week, 70, resetIn: 1_440)]),
                report("node", [limit(.session, 5, resetIn: 280)]),
            ], now: now)
            t.expectEqual(quota.map(\.account), ["this Mac", "node"])
            t.expectEqual(quota.first?.used, 0.7, "the week, 70 % six days in, is the one at risk")
            t.expectEqual(quota.first?.resetInMinutes, 1_440)
            t.expectEqual(quota.first?.runsOutBeforeReset, false, "70 % in six days is 82 % at seven")
        },

        TestCase("The round gives way when the account it runs on would run out, and says so") { t in
            let tight = [report("this Mac", [limit(.session, 60, resetIn: 180)])]
            t.expect(LampMasterQuota.tight(tight, now: now), "this Mac's session window")
            t.expect(!LampMasterQuota.tight([report("this Mac", [limit(.session, 20, resetIn: 180)]),
                                             report("node", [limit(.session, 90, resetIn: 120)])], now: now),
                     "another machine's account is not the one the round spends")
            t.expect(!LampMasterQuota.tight([report("this Mac", [limit(.weekForModel("Fable"), 95, resetIn: 600)])], now: now),
                     "a model's own cap the round does not use")
            let decision = LampMasterSchedule.decide(trigger: .timer, enabled: true, interval: 3_600, lastRun: nil, lastDigest: nil,
                                                     digest: "d", sessionCount: 2, tokensToday: 0, quotaTight: true, now: now)
            t.expectEqual(decision, .skip(.quotaTight))
            let line = LampMasterLine.text(open: 0, last: LampMasterRound(at: now, trigger: .timer, outcome: .skipped, skip: .quotaTight,
                                                                         sessions: 2, digest: "d"),
                                           running: false, time: { _ in "10:00" })
            t.expectEqual(line, "Allowance tight · signals only")
        },
    ])
}
