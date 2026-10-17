import LampBoardCore
import Foundation
import TestKit

/// A conversation Claude Code compacts by itself while nobody is typing (D177).
///
/// Reported on 2.3.0: a session on the always-on machine had finished its last
/// turn at 08:39:58. At 09:33:47 Claude Code started compacting it on its own,
/// "before the prompt cache expired", and while it did its session file said
/// `busy`. The panel took that word (D141) and lit the row yellow. The
/// compaction ended at 09:34:57 with a `SessionStart` of source `compact`, which
/// the reducer ignores on purpose (it also fires inside a turn), and the file
/// went back to `idle`, which nothing read. The row stayed yellow, and a click
/// could not clear it: yellow is not a colour a click clears.
enum IdleCompactionSuite {

    private static let workspace = Workspace(path: "/home/dev/awevents", host: "node")
    private static let id = "6c1f938e"

    /// 17 October 2026, local time on the machine that reported it.
    private static func at(_ clock: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-10-17T\(clock)+02:00")!
    }

    private static func signal(_ event: HookEventKind, source: String? = nil) -> ReducerAction {
        .signal(
            HookSignal(sessionId: id, event: event, cwd: workspace.path, entrypoint: "cli", sessionSource: source),
            workspace: workspace, origin: .terminal
        )
    }

    private static func run(_ steps: [(String, ReducerAction)], from state: TrafficLightState = .empty) -> TrafficLightState {
        steps.reduce(state) { partial, step in StateReducer.reduce(partial, action: step.1, now: at(step.0)) }
    }

    private static func row(_ state: TrafficLightState) -> SessionState? { state.sessions[id] }

    /// The morning as it was recorded, up to the compaction's end.
    private static let morning: [(String, ReducerAction)] = [
        ("08:31:02", signal(.userPromptSubmit)),
        ("08:39:58", signal(.stop)),
        ("08:52:10", .markSeen(sessionId: id)),
        // The probe, while Claude Code compacted: its file said `busy`.
        ("09:34:07", .busy(sessionId: id)),
    ]

    static let suite = TestSuite("A conversation compacted while idle", [

        TestCase("The recorded morning: the row rests when the compaction ends, and is not green") { t in
            let lit = run(morning)
            t.expectEqual(row(lit)?.status, .working, "the file's busy still lights it, as D141 says")
            let after = run([("09:34:56", signal(.sessionStart, source: "compact"))], from: lit)
            t.expectEqual(row(after)?.status, .idle,
                          "an idle compaction leaves the row at rest: there was no turn, and there is no new answer")
        },

        TestCase("A row adopted while Claude Code compacted rests when the compaction ends") { t in
            let adopted = StateReducer.reduce(.empty, action: .adopt(SessionState(
                id: id, status: .working, workspace: workspace, updatedAt: at("08:39:58"),
                statusSince: at("08:39:58"), entrypoint: "cli", origin: .terminal
            )), now: at("09:34:00"))
            t.expect(row(adopted)?.litByFile == true, "a row adopted working was lit by the file")
            let after = run([("09:34:56", signal(.sessionStart, source: "compact"))], from: adopted)
            t.expectEqual(row(after)?.status, .idle, "and it rests like one the probe lit")
        },

        TestCase("A compaction inside a turn the hooks opened keeps the yellow") { t in
            let state = run([
                ("10:00:00", signal(.userPromptSubmit)),
                ("10:00:05", signal(.preToolUse)),
                ("10:01:20", signal(.sessionStart, source: "compact")),
            ])
            t.expectEqual(row(state)?.status, .working, "a compaction mid-turn is a pause in the turn, not its end")
        },

        TestCase("Once a hook speaks for the turn, a compaction keeps the yellow the file lit") { t in
            let state = run(morning + [
                ("09:40:00", signal(.preToolUse)),
                ("09:41:00", signal(.sessionStart, source: "compact")),
            ])
            t.expect(row(state)?.litByFile == false, "the hook took the row over from the file")
            t.expectEqual(row(state)?.status, .working, "and a turn the hooks see is a turn")
        },

        // MARK: The file's word against a yellow that outlived it

        TestCase("A yellow rests a minute after Claude Code's file says idle with no turn open") { t in
            // The same morning with the compaction's hook lost: only the file
            // can say it is over.
            let lit = run(morning)
            let rest = ReducerAction.fileRest(sessionId: id, idleSince: at("09:34:57"), turnIsOpen: nil, readAt: at("09:36:10"))
            let after = StateReducer.reduce(lit, action: rest, now: at("09:36:10"))
            t.expectEqual(row(after)?.status, .idle, "the file's idle, a minute old, outweighs a yellow nothing renews")
        },

        TestCase("Not before the file has said idle for a minute") { t in
            let lit = run(morning)
            let early = ReducerAction.fileRest(sessionId: id, idleSince: at("09:34:57"), turnIsOpen: false, readAt: at("09:35:30"))
            t.expectEqual(row(StateReducer.reduce(lit, action: early, now: at("09:35:30")))?.status, .working,
                          "thirty-three seconds of idle is not yet a rest")
        },

        TestCase("Not while the hooks spoke within the minute") { t in
            let busy = run([("10:00:00", signal(.userPromptSubmit)), ("10:05:30", signal(.postToolUse))])
            let rest = ReducerAction.fileRest(sessionId: id, idleSince: at("10:04:00"), turnIsOpen: false, readAt: at("10:06:00"))
            t.expectEqual(row(StateReducer.reduce(busy, action: rest, now: at("10:06:00")))?.status, .working,
                          "a hook thirty seconds ago outweighs the file")
        },

        TestCase("Not while the transcript shows the turn open") { t in
            let busy = run([("10:00:00", signal(.userPromptSubmit))])
            let rest = ReducerAction.fileRest(sessionId: id, idleSince: at("10:00:30"), turnIsOpen: true, readAt: at("10:05:00"))
            t.expectEqual(row(StateReducer.reduce(busy, action: rest, now: at("10:05:00")))?.status, .working,
                          "an open turn in the tail is a turn")
        },

        TestCase("Not on a reading older than the hooks' last word") { t in
            let busy = run([("10:00:00", signal(.userPromptSubmit))])
            let stale = ReducerAction.fileRest(sessionId: id, idleSince: at("09:00:00"), turnIsOpen: false, readAt: at("09:59:59"))
            t.expectEqual(row(StateReducer.reduce(busy, action: stale, now: at("10:02:00")))?.status, .working,
                          "a file read before the prompt says nothing about the turn it started")
        },

        TestCase("A lost Stop: the turn the hooks opened rests once the file has said idle for a minute") { t in
            let busy = run([("10:00:00", signal(.userPromptSubmit)), ("10:00:20", signal(.postToolUse))])
            let rest = ReducerAction.fileRest(sessionId: id, idleSince: at("10:00:40"), turnIsOpen: false, readAt: at("10:02:00"))
            let after = StateReducer.reduce(busy, action: rest, now: at("10:02:00"))
            t.expectEqual(row(after)?.status, .idle, "at rest, not green: nothing says an answer arrived")
        },

        TestCase("Only a working row rests; no row is made") { t in
            for status in [SessionStatus.ready, .awaiting, .waiting, .failed, .idle] {
                let state = TrafficLightState(sessions: [id: SessionState(
                    id: id, status: status, workspace: workspace, updatedAt: at("08:00:00"), statusSince: at("08:00:00")
                )])
                let rest = ReducerAction.fileRest(sessionId: id, idleSince: at("08:10:00"), turnIsOpen: false, readAt: at("09:00:00"))
                t.expectEqual(row(StateReducer.reduce(state, action: rest, now: at("09:00:00")))?.status, status, "\(status)")
            }
            let none = StateReducer.reduce(.empty, action: .fileRest(
                sessionId: id, idleSince: at("08:10:00"), turnIsOpen: false, readAt: at("09:00:00")
            ), now: at("09:00:00"))
            t.expect(none.sessions.isEmpty, "a file is not a reason to make a row")
        },

        TestCase("A blue the file lit is the file's to end; a blue the hooks gave is theirs") { t in
            // A background shell after the turn (`shell`), or `busy` with the
            // turn closed: the file paints the row blue, and no hook of a turn
            // will end it.
            let idleRow = TrafficLightState(sessions: [id: SessionState(
                id: id, status: .idle, workspace: workspace, updatedAt: at("08:00:00"), statusSince: at("08:00:00")
            )])
            let lit = StateReducer.reduce(idleRow, action: .busy(sessionId: id, status: .waiting), now: at("08:05:00"))
            t.expectEqual(row(lit)?.litByFile, true, "lit by its file, blue as yellow")
            let rest = ReducerAction.fileRest(sessionId: id, idleSince: at("08:10:00"), turnIsOpen: false, readAt: at("09:00:00"))
            t.expectEqual(row(StateReducer.reduce(lit, action: rest, now: at("09:00:00")))?.status, .idle,
                          "the file's idle, a minute old, rests a blue it lit")
            let heard = run([("08:00:00", signal(.userPromptSubmit)), ("08:01:00", signal(.stop))])
            let blue = TrafficLightState(sessions: [id: (row(heard) ?? SessionState(
                id: id, status: .idle, workspace: workspace, updatedAt: at("08:00:00"), statusSince: at("08:00:00")
            )).with(status: .waiting, at: at("08:01:00"))])
            t.expectEqual(row(StateReducer.reduce(blue, action: rest, now: at("09:00:00")))?.status, .waiting,
                          "a blue from the hooks waits for the work they announced")
        },

        // MARK: Reading the file and the tail

        TestCase("The session file's idle carries its moment; any other word carries none") { t in
            let idle = try? LiveSessionParser.parse(data: Data(
                #"{"sessionId":"s","cwd":"/x","status":"idle","statusUpdatedAt":1792222497620}"#.utf8), modifiedAt: at("09:00:00"))
            t.expectEqual(idle?.idleSince, Date(timeIntervalSince1970: 1_792_222_497.620), "idle since its statusUpdatedAt")
            let busy = try? LiveSessionParser.parse(data: Data(
                #"{"sessionId":"s","cwd":"/x","status":"busy","statusUpdatedAt":1792222497620}"#.utf8), modifiedAt: at("09:00:00"))
            t.expectNil(busy?.idleSince, "busy is not a rest")
            let silent = try? LiveSessionParser.parse(data: Data(#"{"sessionId":"s","cwd":"/x","status":"idle"}"#.utf8),
                                                      modifiedAt: at("09:00:00"))
            t.expectNil(silent?.idleSince, "no moment, no rest: an older Claude Code says nothing to measure")
        },

        TestCase("Busy on this Mac lights a row only while the tail does not show the turn ended") { t in
            let busy = try? LiveSessionParser.parse(data: Data(#"{"sessionId":"s","cwd":"/x","status":"busy"}"#.utf8),
                                                    modifiedAt: at("09:00:00"))
            t.expectEqual(busy?.with(turnIsOpen: false).isBusy, false, "a closed turn: background work or a compaction")
            t.expectEqual(busy?.with(turnIsOpen: true).isBusy, true, "an open turn")
            t.expectEqual(busy?.with(turnIsOpen: nil).isBusy, true, "a tail that cannot say keeps the file's word")
            t.expectEqual(busy?.with(turnIsOpen: false).turnIsOpen, false, "and the tail's word is kept")
        },

        TestCase("Another machine's idle carries its moment and its tail's turn") { t in
            let tail = #"{"type":"system","subtype":"turn_duration","timestamp":"2026-10-17T06:39:58Z"}"#
            let object: [String: Any] = [
                "pid": 2124, "sessionId": id, "cwd": "/home/dev/awevents", "activityEpoch": 1,
                "status": "idle", "statusUpdatedAt": 1_792_222_497_620, "contextTail": tail,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: [object])) ?? Data()
            let session = (try? RemoteSessionsDecoder.decode(data, host: "node"))?.first
            t.expectEqual(session?.idleSince, Date(timeIntervalSince1970: 1_792_222_497.620), "the node's own moment")
            t.expectEqual(session?.turnIsOpen, false, "and its turn, closed")
            for field in ["statusUpdatedAt", "isCompactSummary"] {
                t.expect(RemoteProbeScript.script.contains("\"\(field)\""), "the probe must send \(field)")
            }
        },

        TestCase("A compaction's summary is not a prompt: an idle compaction leaves the turn closed") { t in
            let idle = """
            {"type":"assistant","timestamp":"2026-10-17T06:39:50Z","message":{"stop_reason":"end_turn"}}
            {"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-17T06:39:58Z"}
            {"type":"system","subtype":"turn_duration","timestamp":"2026-10-17T06:39:58Z"}
            {"type":"system","subtype":"compact_boundary","timestamp":"2026-10-17T07:34:56Z"}
            {"type":"user","isCompactSummary":true,"timestamp":"2026-10-17T07:34:56Z"}
            {"type":"attachment","timestamp":"2026-10-17T07:34:56Z"}
            {"type":"system","subtype":"informational","timestamp":"2026-10-17T07:34:57Z"}
            {"type":"last-prompt"}
            """
            t.expectEqual(TranscriptActivity.turnIsOpen(inTailChunk: idle, isWholeFile: true), false,
                          "the summary Claude Code wrote for itself opens no turn")
            let midTurn = """
            {"type":"user","timestamp":"2026-10-17T10:00:00Z"}
            {"type":"assistant","timestamp":"2026-10-17T10:00:05Z","message":{"stop_reason":"tool_use"}}
            {"type":"user","timestamp":"2026-10-17T10:00:06Z"}
            {"type":"system","subtype":"compact_boundary","timestamp":"2026-10-17T10:01:20Z"}
            {"type":"user","isCompactSummary":true,"timestamp":"2026-10-17T10:01:20Z"}
            """
            t.expectEqual(TranscriptActivity.turnIsOpen(inTailChunk: midTurn, isWholeFile: true), true,
                          "a compaction inside a turn leaves it open")
        },
    ])
}
