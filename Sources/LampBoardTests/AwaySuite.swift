import LampBoardCore
import Foundation
import TestKit

/// "I'm away" (§5.8, A1): while the person is away nothing interrupts them, and
/// when they come back one line says what happened.
enum AwaySuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(_ id: String, _ status: SessionStatus, cost: Double? = nil) -> SessionState {
        SessionState(id: id, status: status, workspace: Workspace(path: "/home/dev/\(id)"),
                     updatedAt: t0, statusSince: t0, costUSD: cost)
    }

    static func state(_ sessions: [SessionState]) -> TrafficLightState {
        TrafficLightState(sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }))
    }

    static let suite = TestSuite("Away", [

        TestCase("Away, each session's answers, failures and asks are counted as they happen") { t in
            let start = state([session("api", .working, cost: 1.0), session("docs", .working, cost: 0.5)])
            var ledger = AwayLedger(since: t0, state: start)
            ledger.observe(state([session("api", .ready, cost: 1.4), session("docs", .working, cost: 0.5)]))
            ledger.observe(state([session("api", .working, cost: 1.6), session("docs", .failed, cost: 0.7)]))
            ledger.observe(state([session("api", .ready, cost: 2.1), session("docs", .failed, cost: 0.7)]))
            ledger.observe(state([session("api", .awaiting, cost: 2.2), session("docs", .failed, cost: 0.7)]))
            t.expectEqual(ledger.answers, ["api": 2])
            t.expectEqual(ledger.failed, ["docs"])
        },

        TestCase("Back, one line of what the rows no longer show: earlier answers, earlier failures, the cost") { t in
            let start = state([session("api", .working, cost: 1.0), session("docs", .working, cost: 0.5)])
            var ledger = AwayLedger(since: t0, state: start)
            ledger.observe(state([session("api", .ready, cost: 1.4), session("docs", .failed, cost: 0.7)]))
            let back = state([session("api", .awaiting, cost: 2.6), session("docs", .failed, cost: 0.7)])
            ledger.observe(back)
            let line = ledger.summary(now: t0.addingTimeInterval(80 * 60), state: back) { $0 }
            // api's answer is gone from its row (it asks now); docs is still red,
            // and what still waits is amber on its row: neither is repeated (U2).
            t.expectEqual(line, "While you were away (1h 20m): 1 earlier answer (api), $1.80 spent.")
        },

        TestCase("What the rows still say is not said again; a failure since restarted is") { t in
            let start = state([session("api", .working), session("docs", .working)])
            var ledger = AwayLedger(since: t0, state: start)
            ledger.observe(state([session("api", .ready), session("docs", .failed)]))
            let back = state([session("api", .ready), session("docs", .working)])
            ledger.observe(back)
            t.expectEqual(ledger.summary(now: t0.addingTimeInterval(600), state: back) { $0 },
                          "While you were away (10m): 1 earlier failure (docs).")
        },

        TestCase("Nothing the rows do not already show: no line at all, never «nothing happened»") { t in
            let quiet = state([session("api", .idle)])
            let ledger = AwayLedger(since: t0, state: quiet)
            t.expectNil(ledger.summary(now: t0.addingTimeInterval(600), state: quiet) { $0 })
            var busy = AwayLedger(since: t0, state: quiet)
            busy.observe(state([session("api", .idle), session("new", .ready)]))
            t.expectEqual(busy.summary(now: t0.addingTimeInterval(20), state: state([session("api", .idle)])) { $0 },
                          "While you were away (under a minute): 1 earlier answer (new).",
                          "an answer counts even from a session that has gone since; not \"(0m)\"")
        },
    ])
}
