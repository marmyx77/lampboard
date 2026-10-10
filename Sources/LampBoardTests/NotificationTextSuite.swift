import LampBoardCore
import Foundation
import TestKit

/// What a notification says, and the menu bar's count (plan 5.6).
enum NotificationTextSuite {

    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(
        _ status: SessionStatus, ask: PendingAsk? = nil, message: String? = nil, title: String? = nil,
        failure: StopFailureReason? = nil
    ) -> SessionState {
        SessionState(id: "s", status: status, workspace: Workspace(path: "/home/dev/docs-site"), lastMessage: message,
                     updatedAt: at, statusSince: at, failureReason: failure, pendingAsk: ask, title: title)
    }

    static let suite = TestSuite("What a notification says", [

        TestCase("A waiting session says what it waits on, never the previous answer") { t in
            let waiting = session(.awaiting, ask: PendingAsk(tool: "Bash", detail: "npm publish"),
                                  message: "The reply from the turn before")
            t.expectEqual(NotificationText.body(for: .waiting, session: waiting), "Waiting for you · Bash: npm publish")
            t.expectEqual(NotificationText.body(for: .waiting, session: session(.awaiting, title: "Rewrite the guide")),
                          "Waiting for your answer: Rewrite the guide")
            t.expectEqual(NotificationText.body(for: .waiting, session: session(.awaiting, message: "old")),
                          "Waiting for your answer.")
        },

        TestCase("A failed turn says why") { t in
            t.expectEqual(NotificationText.body(for: .failed, session: session(.failed, failure: .rateLimit)),
                          "The turn ended: request limit reached")
            t.expectEqual(NotificationText.body(for: .failed, session: session(.failed)), "The turn ended with an error.")
        },

        TestCase("A finished turn gives its first line, without Markdown, and a long one is cut") { t in
            let answer = "## Done\n\n- Rewrote the install guide in three paths\n- Two links to check"
            t.expectEqual(NotificationText.body(for: .finished, session: session(.ready, message: answer)), "Finished · Done")
            let long = String(repeating: "word ", count: 80)
            let body = NotificationText.body(for: .finished, session: session(.ready, message: long))
            t.expectEqual(body.count, NotificationText.bodyLimit)
            t.expect(body.hasSuffix("…"), "the cut says so")
            t.expectEqual(NotificationText.body(for: .finished, session: session(.ready, message: "\n  \n")), "Finished.")
        },

        TestCase("The menu bar counter: what wants you, then what works, zeros included") { t in
            let summary = MenuBarSummary(lamp: .awaiting, count: 1, blinks: true,
                                         counts: [.awaiting: 1, .ready: 2, .failed: 1, .working: 3, .idle: 4])
            t.expectEqual(summary.counter, "4 · 3")
            let calm = MenuBarSummary(lamp: .working, count: 2, blinks: false, counts: [.working: 2, .idle: 1])
            t.expectEqual(calm.counter, "0 · 2")
            t.expectEqual(MenuBarSummary.empty.counter, "")
        },
        TestCase("An alert is taken back once its news is stale: answered, started again, read, or the session gone") { t in
            t.expectEqual(NotificationText.stale(before: .awaiting, after: .working), [.waiting], "the permission was answered")
            t.expectEqual(NotificationText.stale(before: .failed, after: .working), [.failed], "the turn started again")
            t.expectEqual(NotificationText.stale(before: .ready, after: .idle), [.finished], "the answer was read")
            t.expectEqual(NotificationText.stale(before: .awaiting, after: .awaiting), [], "still waiting: the alert stays")
            t.expectEqual(NotificationText.stale(before: .working, after: .ready), [], "news, not stale")
            t.expectEqual(NotificationText.stale(before: .awaiting, after: nil), [.waiting, .failed, .finished], "gone")
            t.expectEqual(NotificationText.stale(before: nil, after: .awaiting), [], "new")
            t.expectEqual(NotificationText.identifier(.waiting, session: "s1"), "lampboard.waiting.s1")
        },
    ])
}
