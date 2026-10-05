import LampBoardCore
import Foundation
import TestKit

/// The lamp's shape (UX §4, R4): solid as always; dashed while a working session
/// is stuck on one tool; hollow for a session with no mod, when the mod is in use.
enum LampStyleSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(_ id: String, _ status: SessionStatus, reported: Bool = false, tool: RunningTool? = nil,
                        firstSeen: Date = t0.addingTimeInterval(-3600), host: String? = nil) -> SessionState {
        SessionState(id: id, status: status, workspace: Workspace(path: "/home/dev/\(id)", host: host),
                     updatedAt: t0, statusSince: t0,
                     context: reported ? ContextReading(tokens: 1000, model: "claude-opus-5-5", window: 200_000, confidence: .reported, at: t0) : nil,
                     runningTool: tool, firstSeenAt: firstSeen)
    }

    static func style(_ session: SessionState, modInUse: Bool = true) -> LampStyle {
        ColumnRow(id: "r", workspace: session.workspace, sessions: [session]).lampStyle(now: t0, modInUse: modInUse)
    }

    static let suite = TestSuite("The lamp's shape", [

        TestCase("Working and stuck on one tool a quarter of an hour: dashed; working otherwise: solid") { t in
            let stuck = RunningTool(tool: "Bash", detail: "npm install", since: t0.addingTimeInterval(-20 * 60))
            let fresh = RunningTool(tool: "Bash", detail: "npm test", since: t0.addingTimeInterval(-60))
            t.expectEqual(style(session("a", .working, reported: true, tool: stuck)), .stalled)
            t.expectEqual(style(session("a", .working, reported: true, tool: fresh)), .solid)
        },

        TestCase("No mod heard from a session that has had time to speak, while the mod is in use: hollow") { t in
            t.expectEqual(style(session("a", .ready)), .hollow)
            t.expectEqual(style(session("a", .ready, reported: true)), .solid, "the mod has spoken")
            t.expectEqual(style(session("a", .ready), modInUse: false), .solid, "nobody runs the mod: nothing stands out")
            t.expectEqual(style(session("a", .ready, firstSeen: t0.addingTimeInterval(-30))), .solid, "just started: not yet")
            t.expectEqual(style(session("a", .ready, host: "node")), .solid, "another machine: not this panel's to say")
        },
    ])
}
