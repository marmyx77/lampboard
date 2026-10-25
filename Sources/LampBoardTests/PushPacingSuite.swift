import Foundation
import LampBoardCore
import TestKit

/// How often a source updates a Live Activity, and what a relay's "quota" holds
/// back: the relay allows 120 updates an hour and counts each kind apart
/// (`relay/lib/quota.js`). On 24 October 2026 a node sent 121 in sixteen
/// minutes, and the quota it spent silenced its alerts too.
enum PushPacingSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static let suite = TestSuite("Push pacing", [

        TestCase("A few updates at once after a quiet spell, then one every refill") { t in
            var budget = LiveActivityBudget()
            let burst = Int(LiveActivityBudget.burst)
            t.expectEqual((0..<burst).filter { _ in budget.take(at: t0) }.count, burst, "the first waits show at once")
            t.expect(!budget.take(at: t0 + 1), "then the budget is spent")
            t.expect(budget.take(at: t0 + 1 + LiveActivityBudget.refill), "and one comes back after the refill")
        },

        TestCase("Asked every second for an hour, the budget stays under the relay's 120") { t in
            var budget = LiveActivityBudget()
            let sent = (0..<3600).filter { budget.take(at: t0 + Double($0)) }.count
            t.expect(sent < 120, "under the relay's quota: \(sent) in an hour")
            t.expect(sent >= 100, "and still following the work: \(sent) in an hour")
        },

        TestCase("A quota holds back the kind it was spent on, never the others") { t in
            var holds = RelayHolds()
            holds.heard(.quota(retryAfter: 1919), for: .liveactivity, at: t0)
            t.expect(holds.holds(.liveactivity, at: t0 + 60), "the Live Activity waits")
            t.expect(!holds.holds(.alert, at: t0 + 60), "a question still rings")
            t.expect(!holds.holds(.background, at: t0 + 60), "the widgets still hear")
            t.expect(holds.any(at: t0 + 60), "something waits")
            t.expect(!holds.holds(.liveactivity, at: t0 + 1920), "until the time it asked for")
            holds.heard(.quota(retryAfter: 600), for: .alert, at: t0)
            holds.heard(.ok, for: .alert, at: t0 + 10)
            t.expect(!holds.holds(.alert, at: t0 + 20), "an ok since lifts the wait")
        },
    ])
}
