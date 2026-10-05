import LampBoardCore
import Foundation
import TestKit

/// The row's ✉n (UX §4, R3c): how many answers a session has given since the
/// person last looked. One is what green already says; the count is for a
/// session woken again and again — by its background work, by another session's
/// message — with nobody reading in between.
enum UnreadAnswersSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let workspace = Workspace(path: "/Users/dev/Development/events")

    static func signal(_ event: HookEventKind) -> HookSignal {
        HookSignal(sessionId: "s1", event: event, cwd: workspace.path, entrypoint: "cli",
                   lastAssistantMessage: event == .stop ? "Done." : nil)
    }

    static func run(_ events: [HookEventKind], from state: TrafficLightState = .empty) -> TrafficLightState {
        events.reduce(state) { StateReducer.reduce($0, action: .signal(signal($1), workspace: workspace), now: t0) }
    }

    static func unread(_ state: TrafficLightState) -> Int { state.sessions["s1"]?.unreadAnswers ?? -1 }

    static let suite = TestSuite("Unread answers", [

        TestCase("Each answer nobody read adds one; a prompt of the person's starts again") { t in
            let once = run([.userPromptSubmit, .stop])
            t.expectEqual(unread(once), 1)
            // Woken by its own background work: a turn begins with no prompt.
            let thrice = run([.preToolUse, .stop, .preToolUse, .stop], from: once)
            t.expectEqual(unread(thrice), 3)
            t.expectEqual(unread(run([.userPromptSubmit], from: thrice)), 0, "the person was there to type")
        },

        TestCase("Looking clears it; 'mark as unread' brings back one, never more") { t in
            let three = run([.userPromptSubmit, .stop, .preToolUse, .stop, .preToolUse, .stop])
            let seen = StateReducer.reduce(three, action: .markSeen(sessionId: "s1"), now: t0)
            t.expectEqual(unread(seen), 0)
            t.expectEqual(unread(StateReducer.reduce(seen, action: .markUnread(sessionId: "s1"), now: t0)), 1)
        },

        TestCase("A turn that failed or is still waiting on work is not an answer to read") { t in
            t.expectEqual(unread(run([.userPromptSubmit, .stopFailure])), 0)
            t.expectEqual(unread(run([.userPromptSubmit, .preToolUse])), 0)
        },

        TestCase("The badge says it from two on: one is what green already says") { t in
            func row(_ events: [HookEventKind]) -> ColumnRow {
                let session = run(events).sessions["s1"]!
                return ColumnRow(id: "row", workspace: workspace, sessions: [session])
            }
            t.expectNil(row([.userPromptSubmit, .stop]).unreadBadge)
            t.expectEqual(row([.userPromptSubmit, .stop, .preToolUse, .stop]).unreadBadge, "✉2")
            t.expectNil(row([.userPromptSubmit, .stop, .preToolUse, .stop, .userPromptSubmit]).unreadBadge,
                        "a row at work has nothing waiting to be read")
        },
    ])
}
