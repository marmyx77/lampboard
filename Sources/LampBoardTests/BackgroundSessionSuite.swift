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
    ])
}
