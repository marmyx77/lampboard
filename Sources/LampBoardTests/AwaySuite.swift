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

        TestCase("Back, one line: how long, the answers, what still waits, the failures and what it cost") { t in
            let start = state([session("api", .working, cost: 1.0), session("docs", .working, cost: 0.5)])
            var ledger = AwayLedger(since: t0, state: start)
            ledger.observe(state([session("api", .ready, cost: 1.4), session("docs", .failed, cost: 0.7)]))
            let back = state([session("api", .awaiting, cost: 2.6), session("docs", .failed, cost: 0.7)])
            ledger.observe(back)
            let line = ledger.summary(now: t0.addingTimeInterval(80 * 60), state: back) { $0 }
            t.expectEqual(line, "While you were away (1h 20m): 1 answer (api), 1 waiting for you (api), 1 failed (docs), $1.80 spent.")
        },

        TestCase("Nothing happened: said in as many words; a session that came and went is still counted") { t in
            let quiet = state([session("api", .idle)])
            let ledger = AwayLedger(since: t0, state: quiet)
            t.expectEqual(ledger.summary(now: t0.addingTimeInterval(600), state: quiet) { $0 },
                          "While you were away (10m): nothing happened.")
            var busy = AwayLedger(since: t0, state: quiet)
            busy.observe(state([session("api", .idle), session("new", .ready, cost: 0.2)]))
            t.expect(busy.summary(now: t0.addingTimeInterval(600), state: state([session("api", .idle)])) { $0 }
                .contains("1 answer (new)"), "an answer counts even from a session that has gone since")
            t.expect(ledger.summary(now: t0.addingTimeInterval(20), state: quiet) { $0 }.hasPrefix("While you were away (under a minute)"),
                     "not \"(0m)\"")
        },
    ])
}
