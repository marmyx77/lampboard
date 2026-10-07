import LampBoardCore
import Foundation
import TestKit

/// The count in the bar that replaces the queue (U2): how many sessions need you,
/// how many answers wait to be read, how many turns stopped. The rows say which.
enum BarCountSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(_ id: String, _ status: SessionStatus) -> SessionState {
        SessionState(id: id, status: status, workspace: Workspace(path: "/home/dev/\(id)"), updatedAt: t0, statusSince: t0)
    }

    private static func line(_ sessions: [SessionState], asks: [PermissionGate.Request] = []) -> String? {
        WaitingQueue.countLine(WaitingQueue.cards(sessions: sessions, suggestions: [], asks: asks, now: t0))
    }

    static let suite = TestSuite("The bar's count", [

        TestCase("Each kind counted once, the most urgent first, and only what there is") { t in
            t.expectEqual(line([row("api", .awaiting), row("docs", .ready), row("mobile", .failed), row("web", .working)]),
                          "1 needs you · 1 to read · 1 stopped")
            t.expectEqual(line([row("docs", .ready)]), "1 to read")
            t.expectNil(line([row("web", .working), row("old", .idle)]), "nothing waits: no count at all")
        },

        TestCase("Plural, and answers in a group counted one by one") { t in
            t.expectEqual(line([row("a", .awaiting), row("b", .awaiting), row("r1", .ready), row("r2", .ready), row("r3", .ready)]),
                          "2 need you · 3 to read")
        },

        TestCase("A permission the panel holds needs you even though its row is not amber") { t in
            let held = PermissionGate.Request(sessionId: "api", callId: "c1", tool: "Bash", line: "Bash: npm publish", receivedAt: t0)
            t.expectEqual(line([row("api", .working)], asks: [held]), "1 needs you")
            t.expectEqual(line([row("api", .awaiting)], asks: [held]), "1 needs you",
                          "amber and held at once is one session asking, not two")
        },

        TestCase("The asks the panel holds, by session: the rows that draw Allow and Deny") { t in
            let held = PermissionGate.Request(sessionId: "api", callId: "c1", tool: "Bash", line: "Bash: npm publish", receivedAt: t0)
            let cards = WaitingQueue.cards(sessions: [row("api", .working), row("docs", .awaiting)], suggestions: [], asks: [held], now: t0)
            t.expectEqual(WaitingQueue.held(in: cards).keys.sorted(), ["api"], "an amber row's dialog is in its terminal, not here")
            t.expectEqual(WaitingQueue.held(in: cards)["api"]?.call, "c1")
        },
    ])
}
