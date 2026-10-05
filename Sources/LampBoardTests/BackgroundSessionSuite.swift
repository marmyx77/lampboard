import LampBoardCore
import Foundation
import TestKit

/// The Agent View's background sessions (§5.14, AV1): `claude --bg` writes a
/// session file with `kind: "bg"`, sends its hooks, and until now was dropped
/// as not interactive. A session working for you unseen is exactly the one a
/// person needs a lamp for.
enum BackgroundSessionSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func live(kind: String?, entrypoint: String? = "cli") -> LiveSession {
        LiveSession(pid: 4242, sessionId: "4b138f7d-67ab-4d4c-9396-77adaed0f851", cwd: "/home/dev/events",
                    entrypoint: entrypoint, name: nil, kind: kind, modifiedAt: t0)
    }

    static let suite = TestSuite("Background sessions", [

        TestCase("A background session deserves a lamp; other kinds that are not interactive do not") { t in
            t.expect(live(kind: "bg").deservesTrafficLight, "bg")
            t.expect(live(kind: "bg").isBackground, "and says so")
            t.expect(live(kind: "interactive").deservesTrafficLight && !live(kind: "interactive").isBackground, "interactive")
            t.expect(!live(kind: "daemon").deservesTrafficLight, "anything else still out")
            t.expect(!live(kind: "bg", entrypoint: "sdk-cli").deservesTrafficLight, "an SDK entrypoint still out, bg or not")
        },

        TestCase("Its row is named by its title and says it runs in the background") { t in
            let session = SessionState(id: "s1", status: .idle, workspace: Workspace(path: "/home/dev/events"),
                                       updatedAt: t0, statusSince: t0, origin: .background, title: "Fix the slots test")
            t.expectEqual(session.displayName, "Fix the slots test")
            let row = ColumnRow(id: "row-s1", workspace: session.workspace, sessions: [session])
            t.expectEqual(RowActivity.line(for: row, now: t0), "Claude Code · background")
            t.expect(!row.hostsNewConversation, "no window to open a new conversation in")
        },
        TestCase("A job's state file gives its id, its summary, and what it needs only while it is blocked (AV2)") { t in
            let blocked = #"{"sessionId":"s1","state":"working","tempo":"blocked","detail":"fixing the slots test","needs":"approve the migration"}"#
            guard let job = BackgroundJobParser.parse(data: Data(blocked.utf8), id: "4b138f7d") else { return t.fail("not read") }
            t.expectEqual(job.id, "4b138f7d")
            t.expectEqual(job.sessionId, "s1")
            t.expectEqual(job.summary, "fixing the slots test")
            t.expectEqual(job.needs, "approve the migration")
            t.expectEqual(job.attachCommand, "claude attach 4b138f7d")
            let idle = #"{"sessionId":"s1","state":"done","tempo":"idle","detail":"replied","needs":"stale"}"#
            t.expectNil(BackgroundJobParser.parse(data: Data(idle.utf8), id: "4b138f7d")?.needs, "a need outlives no block")
        },

        TestCase("A job's words are one clean line; a job without a session or with an id unfit for a shell is no job (AV2)") { t in
            let long = String(repeating: "x", count: 500)
            let messy = #"{"sessionId":"s1","tempo":"idle","detail":"first\nsecond\u0007 \#(long)"}"#
            let summary = BackgroundJobParser.parse(data: Data(messy.utf8), id: "4b138f7d")?.summary ?? ""
            t.expect(summary.hasPrefix("first second "), "flattened: \(summary.prefix(20))")
            t.expectEqual(summary.count, BackgroundJob.maxLength)
            t.expectNil(BackgroundJobParser.parse(data: Data(#"{"tempo":"idle"}"#.utf8), id: "4b138f7d"), "no session")
            t.expectNil(BackgroundJobParser.parse(data: Data("not json".utf8), id: "4b138f7d"), "not json")
            let ok = #"{"sessionId":"s1"}"#
            t.expectNil(BackgroundJobParser.parse(data: Data(ok.utf8), id: "4b1; rm -rf ~"), "an id that would run something")
            t.expectNil(BackgroundJobParser.parse(data: Data(ok.utf8), id: ""), "an empty id")
            t.expectNil(BackgroundJobParser.parse(data: Data(ok.utf8), id: "--help"), "an id that reads as an option")
            let bidi = #"{"sessionId":"s1","tempo":"blocked","needs":"approve \u202Edeleting\u202C it"}"#
            t.expectEqual(BackgroundJobParser.parse(data: Data(bidi.utf8), id: "a1")?.needs, "approve deleting it",
                          "a bidi override cannot reorder the need")
            t.expectNil(BackgroundJobParser.parse(data: Data(#"{"sessionId":"s1","detail":"  "}"#.utf8), id: "a1")?.summary, "blank is none")
        },

        TestCase("A background session's live file names its job, when the id is fit for a shell (AV2)") { t in
            func parse(_ jobId: String) -> String? {
                let json = #"{"pid":7,"sessionId":"s1","cwd":"/home/dev/events","kind":"bg","jobId":"\#(jobId)"}"#
                return (try? LiveSessionParser.parse(data: Data(json.utf8), modifiedAt: t0))?.jobId
            }
            t.expectEqual(parse("ef10f0c0"), "ef10f0c0")
            t.expectNil(parse("ef1; open -a Calculator"), "refused")
            t.expectEqual(live(kind: "bg").with(modifiedAt: t0).jobId, nil, "none written, none read")
            let named = LiveSession(pid: 7, sessionId: "s1", cwd: "/x", entrypoint: "cli", name: nil, kind: "bg",
                                    modifiedAt: t0, jobId: "ef10f0c0")
            t.expectEqual(named.with(modifiedAt: t0.addingTimeInterval(5)).jobId, "ef10f0c0", "kept by a copy")
        },

        TestCase("A background row reads the job's summary, or what it needs; a held question still says itself (AV2)") { t in
            let job = BackgroundJob(id: "4b138f7d", sessionId: "s1", summary: "slots test fixed", needs: nil)
            func line(_ status: SessionStatus, _ job: BackgroundJob?, ask: PendingAsk? = nil) -> String {
                let session = SessionState(id: "s1", status: status, workspace: Workspace(path: "/home/dev/events"),
                                           lastMessage: "Done. The slots test passes.", updatedAt: t0, statusSince: t0,
                                           pendingAsk: ask, origin: .background, title: "Fix the slots test",
                                           backgroundJob: job)
                return RowActivity.line(for: ColumnRow(id: "row", workspace: session.workspace, sessions: [session]), now: t0)
            }
            t.expectEqual(line(.ready, job), "background · slots test fixed")
            t.expectEqual(line(.idle, job), "background · slots test fixed")
            t.expectEqual(line(.ready, nil), "background · Done. The slots test passes.", "no job, the answer as before")
            let blocked = BackgroundJob(id: "4b138f7d", sessionId: "s1", summary: "slots test", needs: "approve the migration")
            t.expectEqual(line(.awaiting, blocked), "background · approve the migration")
            t.expectEqual(line(.working, blocked), "background · approve the migration")
            t.expectEqual(line(.working, job), "background · working", "working says what it runs, not the summary")
        },

        TestCase("A job attaches to its background row only, creates none, and the same job changes nothing (AV2)") { t in
            let job = BackgroundJob(id: "4b138f7d", sessionId: "s1", summary: "slots test fixed", needs: nil)
            func session(_ id: String, _ origin: SessionOrigin) -> SessionState {
                SessionState(id: id, status: .idle, workspace: Workspace(path: "/home/dev/events"),
                             updatedAt: t0, statusSince: t0, origin: origin)
            }
            let state = TrafficLightState(sessions: ["s1": session("s1", .background), "s2": session("s2", .terminal)])
            let after = StateReducer.reduce(state, action: .jobRead(sessionId: "s1", job: job), now: t0)
            t.expectEqual(after.sessions["s1"]?.backgroundJob, job)
            t.expectEqual(after.sessions["s1"]?.updatedAt, t0, "an observation, not a signal")
            t.expectEqual(StateReducer.reduce(after, action: .jobRead(sessionId: "s1", job: job), now: t0), after)
            t.expectNil(StateReducer.reduce(state, action: .jobRead(sessionId: "s2", job: job), now: t0).sessions["s2"]?.backgroundJob,
                        "a terminal row is not a job")
            t.expectNil(StateReducer.reduce(state, action: .jobRead(sessionId: "s9", job: job), now: t0).sessions["s9"], "no row made")
            t.expectNil(StateReducer.reduce(after, action: .jobRead(sessionId: "s1", job: nil), now: t0).sessions["s1"]?.backgroundJob,
                        "a job gone is gone")
            let snapshot = SessionsCodec.snapshot(of: after.sessions["s1"]!)
            t.expectEqual(snapshot.jobId, "4b138f7d")
            t.expectEqual(snapshot.summary, "slots test fixed")
            t.expectNil(snapshot.needs)
        },
    ])
}
