import LampBoardCore
import Foundation
import TestKit

/// What LampMaster tells without a model: each rule on both sides of its threshold.
enum LampMasterSignalsSuite {

    typealias F = LampMasterFixtures

    static func session(
        _ id: String, _ chunks: [String], _ liveness: LampMasterSession.Liveness = .idle,
        repository: String? = nil, branch: String? = nil, window: Int? = nil
    ) -> LampMasterSession {
        LampMasterSession(card: F.card(id, chunks), liveness: liveness,
                          repository: repository, branch: branch, contextWindow: window)
    }

    static func signals(_ sessions: [LampMasterSession], at minutes: Double) -> [String: [LampMasterSignal]] {
        LampMasterSignals.evaluate(sessions, now: F.at(minutes))
    }

    static let asking = [F.prompt("build it", at: 0), F.answer("The build is ready. Shall I install it?", at: 1)]

    static let suite = TestSuite("LampMaster: signals", [

        TestCase("An idle session that asked waits on you after twenty minutes, not before") { t in
            t.expectEqual(signals([session("a", asking)], at: 20)["a"], [])
            t.expectEqual(signals([session("a", asking)], at: 21)["a"], [.waitingOnYou])
        },

        TestCase("A session asking through the panel's own amber is not doubled") { t in
            t.expectEqual(signals([session("a", asking, .asking)], at: 60)["a"], [])
        },

        TestCase("A turn with nothing new for ten minutes is stuck") { t in
            let working = session("a", [F.prompt("install", at: 0)], .working)
            t.expectEqual(signals([working], at: 9)["a"], [])
            t.expectEqual(signals([working], at: 10)["a"], [.stuck])
        },

        TestCase("The same failure three times in an hour repeats; twice does not") { t in
            func failing(_ times: Int) -> LampMasterSession {
                session("a", (0..<times).flatMap { i in [
                    F.call("c\(i)", tool: "Bash", input: ["command": "pnpm i"], at: Double(i)),
                    F.result("c\(i)", error: true, text: "ERR_PNPM_FETCH_404 on try \(i)", at: Double(i)),
                ] })
            }
            t.expectEqual(signals([failing(2)], at: 5)["a"], [])
            t.expectEqual(signals([failing(3)], at: 5)["a"], [.repeatedFailure(fingerprint: "err_pnpm_fetch_# on try #")])
            t.expectEqual(signals([failing(3)], at: 70)["a"], [], "older than an hour")
        },

        TestCase("Saved after the last prompt, asking nothing, quiet for an hour: finished") { t in
            let saved = [F.prompt("ship it", at: 0),
                         F.call("c", tool: "Bash", input: ["command": "git push"], at: 1),
                         F.result("c", at: 2),
                         F.answer("Pushed to main, all green.", at: 3)]
            t.expectEqual(signals([session("a", saved)], at: 62)["a"], [])
            t.expectEqual(signals([session("a", saved)], at: 63)["a"], [.finished])
            t.expectEqual(signals([session("a", saved, .working)], at: 63)["a"], [.stuck], "a running turn is not finished")
        },

        TestCase("Failing tests are not finished work") { t in
            let red = [F.prompt("test it", at: 0),
                       F.call("c", tool: "Bash", input: ["command": "npm test"], at: 1),
                       F.result("c", error: true, text: "2 failed", at: 2),
                       F.answer("Two tests fail.", at: 3)]
            t.expectEqual(signals([session("a", red)], at: 120)["a"], [])
        },

        TestCase("Context high at 85% of the model's window") { t in
            let full = [F.answer("ok", at: 0, context: 850_000)]
            t.expectEqual(signals([session("a", full, window: 1_000_000)], at: 1)["a"], [.contextHigh])
            t.expectEqual(signals([session("a", [F.answer("ok", at: 0, context: 849_000)], window: 1_000_000)], at: 1)["a"], [])
            t.expectEqual(signals([session("a", [F.answer("ok", at: 0, context: 170_000)])], at: 1)["a"], [.contextHigh],
                          "the 200k default when the window is unknown")
        },

        TestCase("Two sessions writing the same file both know about the other") { t in
            let edit: (String, Double) -> String = { id, at in
                F.call(id, tool: "Edit", input: ["file_path": "/home/dev/api/routes.ts"], at: at)
            }
            let all = signals([session("aaaaaaaa1", [edit("x", 0)]), session("bbbbbbbb2", [edit("y", 5)])], at: 10)
            t.expectEqual(all["aaaaaaaa1"], [.sameFiles(with: "bbbbbbbb")])
            t.expectEqual(all["bbbbbbbb2"], [.sameFiles(with: "aaaaaaaa")])
            let late = signals([session("aaaaaaaa1", [edit("x", 0)]), session("bbbbbbbb2", [edit("y", 5)])], at: 125)
            t.expectEqual(late["aaaaaaaa1"], [], "outside the two hours")
        },

        TestCase("Two live sessions on one branch overlap; a closed one does not") { t in
            let a = session("aaaaaaaa1", [F.prompt("x", at: 0)], repository: "api", branch: "main")
            let b = session("bbbbbbbb2", [F.prompt("y", at: 0)], repository: "api", branch: "main")
            let c = session("cccccccc3", [F.prompt("z", at: 0)], .closed, repository: "api", branch: "main")
            let all = signals([a, b, c], at: 1)
            t.expectEqual(all["aaaaaaaa1"], [.sameBranch(with: "bbbbbbbb")])
            t.expectEqual(all["cccccccc3"], [])
        },
    ])
}
