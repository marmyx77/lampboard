import LampBoardCore
import Foundation
import TestKit

/// `lampboard watch`: a command as a row (D70).
enum WatchSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func report(_ phase: WatchReport.Phase, id: String = "a1b2c3d4e5f60718") -> WatchReport {
        WatchReport(id: id, name: "npm test", cwd: "/home/dev/api", phase: phase)
    }

    static let suite = TestSuite("A command watched as a row", [

        TestCase("What lampboard watch posts is what the panel reads") { t in
            for phase in [WatchReport.Phase.started, .ended(exitCode: 3)] {
                t.expectEqual(try? WatchReport.decode(report(phase).encoded()), report(phase))
            }
        },

        TestCase("Anything else is refused: an odd id, a relative folder, an end with no code") { t in
            let bad = [
                #"{"v":1,"id":"../etc","name":"x","cwd":"/a","phase":"start"}"#,
                #"{"v":1,"id":"a1b2c3d4","name":"x","cwd":"relative","phase":"start"}"#,
                #"{"v":1,"id":"a1b2c3d4","name":"x","cwd":"/a","phase":"end"}"#,
                #"{"v":2,"id":"a1b2c3d4","name":"x","cwd":"/a","phase":"start"}"#,
                #"{"v":1,"id":"a1b2c3d4","name":"","cwd":"/a","phase":"start"}"#,
                #"{"v":1,"id":"a1b2c3d4","name":"x","cwd":"/home/dev/\u202Eipa","phase":"start"}"#,
                #"{"v":1,"id":"a1b2c3d4","name":"x","cwd":"/home/dev\napi","phase":"start"}"#,
            ]
            for json in bad {
                t.expectThrows(WatchReport.Failure.unreadable, json) { _ = try WatchReport.decode(Data(json.utf8)) }
            }
        },

        TestCase("Yellow while it runs, green on 0, red otherwise with the code") { t in
            var state = TrafficLightState()
            state = StateReducer.reduce(state, action: .watched(report(.started)), now: t0)
            let id = report(.started).sessionId
            t.expectEqual(state.sessions[id]?.status, .working)
            t.expectEqual(state.sessions[id]?.harness, .command)
            t.expectEqual(state.sessions[id]?.title, "npm test")
            let green = StateReducer.reduce(state, action: .watched(report(.ended(exitCode: 0))), now: t0.addingTimeInterval(90))
            t.expectEqual(green.sessions[id]?.status, .ready)
            t.expectEqual(green.sessions[id]?.lastMessage, "exited 0 after 1m")
            let red = StateReducer.reduce(state, action: .watched(report(.ended(exitCode: 2))), now: t0.addingTimeInterval(5))
            t.expectEqual(red.sessions[id]?.status, .failed)
            t.expectEqual(red.sessions[id]?.failureReason, .commandFailed)
            t.expectEqual(red.sessions[id]?.lastMessage, "exited with 2 after 5s")
        },

        TestCase("At most twenty command rows: the oldest finished one makes room") { t in
            var state = TrafficLightState()
            for n in 0..<WatchReport.maxRows {
                let id = String(format: "a1b2c3d4%08d", n)
                state = StateReducer.reduce(state, action: .watched(report(.ended(exitCode: 0), id: id)), now: t0.addingTimeInterval(Double(n)))
            }
            state = StateReducer.reduce(state, action: .watched(report(.started, id: "ffffffffffffffff")), now: t0.addingTimeInterval(100))
            t.expectEqual(state.sessions.values.filter { $0.harness == .command }.count, WatchReport.maxRows)
            t.expectNil(state.sessions["watch-a1b2c3d400000000"], "the oldest finished one went")
        },

        TestCase("A command still running is not pruned however long it runs") { t in
            let state = StateReducer.reduce(TrafficLightState(), action: .watched(report(.started)), now: t0)
            let later = state.pruning(olderThan: AppConfig.sessionStaleAfter, at: t0.addingTimeInterval(86_400))
            t.expectNotNil(later.sessions[report(.started).sessionId])
        },

        TestCase("An end whose start the panel missed still makes its row") { t in
            let state = StateReducer.reduce(TrafficLightState(), action: .watched(report(.ended(exitCode: 1))), now: t0)
            t.expectEqual(state.sessions[report(.started).sessionId]?.status, .failed)
        },

        // Measured on the test Mac: with terminal sessions off, the sweep that
        // forgets them took the watched commands too, and the panel stayed empty.
        TestCase("Hiding terminal sessions does not hide a watched command") { t in
            let state = StateReducer.reduce(TrafficLightState(), action: .watched(report(.started)), now: t0)
            let after = StateReducer.reduce(state, action: .forget(origin: .terminal), now: t0)
            t.expectNotNil(after.sessions[report(.started).sessionId])
        },

        // Its rows come only through /watch, behind the token.
        TestCase("No hook can claim to be a command") { t in
            t.expectEqual(Harness.named("command"), .claudeCode)
            t.expectEqual(Harness.command.cannotReport, [.awaiting, .waiting])
        },
    ])
}
