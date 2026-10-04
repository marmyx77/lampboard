import LampBoardCore
import Foundation
import TestKit

/// The frame the hourly round reads: who is in it, in what order, within budget.
enum LampMasterFrameSuite {

    typealias F = LampMasterFixtures

    static func session(_ id: String, _ chunks: [String], _ liveness: LampMasterSession.Liveness = .idle) -> LampMasterSession {
        LampMasterSession(card: F.card(id, chunks), liveness: liveness)
    }

    static let suite = TestSuite("LampMaster: the frame", [

        TestCase("Live sessions and recent closed ones are in; old closed ones are out") { t in
            let frame = LampMasterFrameBuilder.build(sessions: [
                session("live0001", [F.prompt("a", at: 0)], .working),
                session("recent01", [F.answer("done", at: 0)], .closed),
                session("oldclose", [F.answer("done", at: -400)], .closed),
                session("empty001", [], .idle),
            ], now: F.at(10))
            t.expectEqual(Set(frame.sessions.map(\.id)), ["live0001", "recent01"])
        },

        TestCase("A closed session left asking stays in for a week") { t in
            let asking = [F.answer("Which of the two do you want?", at: 0)]
            let days = { (d: Double) in F.at(d * 24 * 60) }
            t.expectEqual(LampMasterFrameBuilder.build(sessions: [session("asked001", asking, .closed)], now: days(6)).sessions.count, 1)
            t.expectEqual(LampMasterFrameBuilder.build(sessions: [session("asked001", asking, .closed)], now: days(8)).sessions.count, 0)
        },

        TestCase("Sessions with signals come first, then live ones, then the most recent") { t in
            let frame = LampMasterFrameBuilder.build(sessions: [
                session("closed01", [F.answer("ok", at: 50)], .closed),
                session("liveidle", [F.answer("ok", at: 10)], .idle),
                session("stuck001", [F.prompt("go", at: 0)], .working),
            ], now: F.at(60))
            t.expectEqual(frame.sessions.map(\.id), ["stuck001", "liveidle", "closed01"])
        },

        TestCase("Files are shown relative to the session's folder") { t in
            let frame = LampMasterFrameBuilder.build(sessions: [
                session("files001", [F.call("c", tool: "Edit", input: ["file_path": "/home/dev/docs-site/src/a.ts"], at: 0)], .working),
            ], now: F.at(1))
            t.expectEqual(frame.sessions.first?.filesLastHour, ["src/a.ts"])
            t.expectEqual(frame.sessions.first?.project, "docs-site")
        },

        // Detail goes before sessions: a closed, quiet session is shortened first,
        // and only when that is not enough does a whole session leave the frame.
        TestCase("Over budget, quiet sessions are compacted before any is dropped") { t in
            let long = String(repeating: "lorem ", count: 70)
            let sessions = (0..<12).map { i in
                session(String(format: "s%07d", i), [F.prompt(long, at: Double(i)), F.answer(long, at: Double(i))], .closed)
            }
            let roomy = LampMasterFrameBuilder.build(sessions: sessions, now: F.at(30))
            t.expectEqual(roomy.sessions.count, 12)
            t.expect(roomy.sessions.allSatisfy { $0.compacted == nil }, "nothing compacted with room to spare")
            let tight = LampMasterFrameBuilder.build(sessions: sessions, now: F.at(30), budgetTokens: 2_500)
            t.expectEqual(tight.sessions.count, 12, "compacting was enough")
            t.expect(tight.sessions.contains { $0.compacted == true }, "something compacted")
            t.expect(tight.estimatedTokens <= 2_500, "within the tight budget")
            let tiny = LampMasterFrameBuilder.build(sessions: sessions, now: F.at(30), budgetTokens: 600)
            t.expect(tiny.sessions.count < 12, "sessions dropped when compacting is not enough")
            t.expect(tiny.estimatedTokens <= 600, "within the tiny budget")
        },

        TestCase("Signals reach the frame as short phrases") { t in
            let frame = LampMasterFrameBuilder.build(sessions: [
                session("stuck001", [F.prompt("go", at: 0)], .working),
            ], now: F.at(30))
            t.expect(frame.json().contains("\"signals\":[\"stuck in a turn\"]"), "signals as phrases")
        },

        TestCase("The notebook is capped") { t in
            let frame = LampMasterFrameBuilder.build(sessions: [], now: F.at(0), notebook: String(repeating: "n", count: 5_000))
            t.expectEqual(frame.notebook.count, 1_500)
        },
    ])
}
