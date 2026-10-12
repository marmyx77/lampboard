import LampBoardCore
import Foundation
import TestKit

/// A session found by its name, and what it has been doing: its tools and its
/// turns, for the file conflicts, the radar and the Hub's file marks.
enum SessionActivitySuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    static let suite = TestSuite("Sessions by name, and what they have been doing", [

        TestCase("A session is found by its id, or by LampMaster's eight characters when they name one") { t in
            func session(_ id: String) -> SessionState {
                SessionState(id: id, status: .idle, workspace: Workspace(path: "/home/dev/x"), updatedAt: t0, statusSince: t0)
            }
            let state = TrafficLightState(sessions: ["e5f6a7b8-1": session("e5f6a7b8-1"), "c0ffee00-2": session("c0ffee00-2"),
                                                     "c0ffee00-3": session("c0ffee00-3")])
            t.expectEqual(state.session(named: "e5f6a7b8-1")?.id, "e5f6a7b8-1", "the whole id")
            t.expectEqual(state.session(named: "e5f6a7b8")?.id, "e5f6a7b8-1", "the short form LampMaster uses")
            t.expectNil(state.session(named: "c0ffee00"), "two sessions share it: neither")
            t.expectNil(state.session(named: "e5f6"), "too short to mean one")
        },

        TestCase("A tool's start and end make one entry with its duration") { t in
            var log = SessionActivity()
            log.toolStarted(id: "c1", tool: "Bash", detail: "npm test", at: at(0))
            log.toolEnded(id: "c1", at: at(12))
            t.expectEqual(log.entries.count, 1)
            t.expectEqual(log.entries.first?.kind, .tool(name: "Bash", detail: "npm test"))
            t.expectEqual(log.entries.first?.seconds, 12)
        },

        TestCase("A tool still running has no duration; an end without its start adds nothing") { t in
            var log = SessionActivity()
            log.toolStarted(id: "c1", tool: "Edit", detail: "src/routes.ts", at: at(0))
            log.toolEnded(id: "unknown", at: at(3))
            t.expectEqual(log.entries.count, 1)
            t.expectNil(log.entries.first?.seconds)
        },

        TestCase("A turn's end is an entry, with what it cost since the last one") { t in
            var log = SessionActivity()
            log.costReported(0.10, at: at(0))
            log.turnEnded(at: at(30))
            log.costReported(0.25, at: at(40))
            log.turnEnded(at: at(60))
            let turns = log.entries.filter { $0.kind == .turn }
            t.expectEqual(turns.count, 2)
            t.expectEqual(turns.last?.costUSD.map { ($0 * 100).rounded() / 100 }, 0.15, "the cost of that turn alone")
        },

        TestCase("The mod's reports feed the log: tools by their call, the cost for the next turn") { t in
            func report(_ json: String) -> ModReport? { try? ModReport.decode(Data(json.utf8)) }
            let id = "5f0c2a7e-1b3d-4c8e-9a6f-2d4b8e1c7a90"
            var log = SessionActivity()
            if let start = report(#"{"v":1,"kind":"tool","session":"\#(id)","id":"toolu_1","tool":"Bash","phase":"start","detail":"make"}"#) {
                log.record(start, at: at(0))
            }
            if let end = report(#"{"v":1,"kind":"tool","session":"\#(id)","id":"toolu_1","tool":"Bash","phase":"end"}"#) {
                log.record(end, at: at(4))
            }
            t.expectEqual(log.entries.first?.seconds, 4, "start and end of one call")
            t.expectEqual(log.entries.first?.kind, .tool(name: "Bash", detail: "make"))
        },

        TestCase("The log keeps the newest entries, and a detail stays one short line") { t in
            var log = SessionActivity()
            for i in 0..<(SessionActivity.kept + 10) {
                log.toolStarted(id: "c\(i)", tool: "Bash", detail: "step \(i)\n" + String(repeating: "x", count: 500), at: at(Double(i)))
            }
            t.expectEqual(log.entries.count, SessionActivity.kept)
            guard case .tool(_, let detail)? = log.entries.last?.kind else { return t.fail("no tool") }
            t.expect(detail?.hasPrefix("step \(SessionActivity.kept + 9)") == true, "the newest kept")
            t.expect((detail?.count ?? 0) <= 120 && detail?.contains("\n") == false, "one short line")
        },
    ])
}
