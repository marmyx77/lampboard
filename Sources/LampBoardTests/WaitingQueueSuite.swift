import LampBoardCore
import Foundation
import TestKit

/// "Waiting for you": what the queue at the top of the panel holds, in which
/// order, and what a key does to it (UX §3).
enum WaitingQueueSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private static func row(
        _ id: String, _ status: SessionStatus, since: Double = 0, ask: PendingAsk? = nil,
        tool: RunningTool? = nil, harness: Harness = .claudeCode, folder: String? = nil
    ) -> SessionState {
        SessionState(id: id, status: status, workspace: Workspace(path: "/home/dev/\(folder ?? id)"),
                     updatedAt: at(since), statusSince: at(since), harness: harness,
                     pendingAsk: ask, runningTool: tool)
    }

    private static func suggestion(_ key: String) -> LampMasterShown {
        LampMasterShown(id: "s-\(key)", at: t0, suggestion: LampMasterAdvice.Suggestion(
            kind: .precedent, sessions: ["aaaaaaaa"], text: "events fixed this yesterday", evidence: "e",
            action: .init(kind: .open), confidence: 0.8, key: key))
    }

    private static func kinds(_ cards: [WaitingCard]) -> [WaitingCard.Kind] { cards.map(\.kind) }

    private static func held(_ session: String, _ call: String, line: String = "Bash: npm publish", at seconds: Double = 0) -> PermissionGate.Request {
        PermissionGate.Request(sessionId: session, callId: call, tool: "Bash", line: line, receivedAt: at(seconds))
    }

    static let suite = TestSuite("The queue of what waits for you", [

        TestCase("Permissions, questions, stuck, failed, ready, LampMaster: urgency, then age") { t in
            let cards = WaitingQueue.cards(sessions: [
                row("ready1", .ready, since: 5),
                row("failed1", .failed, since: 1),
                row("asks", .awaiting, since: 9, ask: PendingAsk(tool: "AskUserQuestion", detail: "Which branch?")),
                row("stuck", .working, since: 0, tool: RunningTool(tool: "Bash", detail: "npm install", since: at(0))),
                row("perm-late", .awaiting, since: 8, ask: PendingAsk(tool: "Bash", detail: "npm publish")),
                row("perm-early", .awaiting, since: 2, ask: PendingAsk(tool: "Edit", detail: "src/routes.ts")),
                row("busy", .working, since: 0),
                row("rest", .idle, since: 0),
            ], suggestions: [suggestion("k")], now: at(20 * 60))
            t.expectEqual(kinds(cards), [.permission, .permission, .question, .stuck, .failed, .ready, .lampMaster])
            t.expectEqual(cards.prefix(2).map(\.sessionIds), [["perm-early"], ["perm-late"]], "the older ask first")
            t.expectEqual(cards[0].line, "Edit: src/routes.ts")
            t.expectEqual(cards[2].line, "AskUserQuestion: Which branch?")
            t.expectEqual(cards[3].line, "Bash: npm install", "the stuck tool and its command")
        },

        TestCase("An amber row with nothing said is a permission all the same") { t in
            let cards = WaitingQueue.cards(sessions: [row("a", .awaiting)], suggestions: [], now: at(1))
            t.expectEqual(kinds(cards), [.permission])
            t.expectEqual(cards.first?.line, "waiting for your answer")
        },

        TestCase("A working row is in the queue only once it is stuck") { t in
            let fresh = row("w", .working, tool: RunningTool(tool: "Bash", detail: "make", since: at(0)))
            t.expect(WaitingQueue.cards(sessions: [fresh], suggestions: [], now: at(14 * 60)).isEmpty, "fourteen minutes")
            t.expectEqual(kinds(WaitingQueue.cards(sessions: [fresh], suggestions: [], now: at(15 * 60))), [.stuck])
        },

        TestCase("Up to two ready answers stand alone; three or more are one card") { t in
            let two = WaitingQueue.cards(sessions: [row("r1", .ready), row("r2", .ready, since: 1)], suggestions: [], now: at(5))
            t.expectEqual(kinds(two), [.ready, .ready])
            let three = WaitingQueue.cards(sessions: [row("r1", .ready), row("r2", .ready, since: 1), row("r3", .ready, since: 2)],
                                           suggestions: [], now: at(5))
            t.expectEqual(kinds(three), [.readyGroup])
            t.expectEqual(three.first?.sessionIds, ["r1", "r2", "r3"])
            t.expectEqual(three.first?.line, "3 answers to read")
        },

        TestCase("LampMaster shows one card, last, and counts the rest") { t in
            let cards = WaitingQueue.cards(sessions: [], suggestions: [suggestion("a"), suggestion("b"), suggestion("c")], now: at(1))
            t.expectEqual(kinds(cards), [.lampMaster])
            t.expectEqual(cards.first?.more, 2, "«+2»")
            t.expectEqual(cards.first?.line, "events fixed this yesterday")
        },

        TestCase("A watched command that failed waits for you; one that succeeded does not ask to be read") { t in
            let cards = WaitingQueue.cards(sessions: [row("c1", .failed, harness: .command), row("c2", .ready, harness: .command)],
                                           suggestions: [], now: at(1))
            t.expectEqual(kinds(cards), [.failed])
        },

        TestCase("A card is armed 600 ms after it appears, not before") { t in
            t.expect(!WaitingQueue.isArmed(appearedAt: at(0), now: at(0.59)), "just under")
            t.expect(WaitingQueue.isArmed(appearedAt: at(0), now: at(0.6)), "on time")
        },

        TestCase("J and K move and stop at the ends; O opens and E marks read the selected card") { t in
            let cards = WaitingQueue.cards(sessions: [
                row("p", .awaiting, ask: PendingAsk(tool: "Bash", detail: "ls")), row("f", .failed), row("r", .ready),
            ], suggestions: [], now: at(5))
            var cursor = WaitingQueue.Cursor()
            t.expectEqual(cursor.press(.next, cards: cards), .moved)
            t.expectEqual(cursor.selected, 1)
            _ = cursor.press(.next, cards: cards)
            t.expectEqual(cursor.press(.next, cards: cards), .none, "already at the last")
            t.expectEqual(cursor.selected, 2)
            t.expectEqual(cursor.press(.open, cards: cards), .open(sessionId: "r"))
            t.expectEqual(cursor.press(.markRead, cards: cards), .markRead(sessionIds: ["r"]))
            _ = cursor.press(.previous, cards: cards); _ = cursor.press(.previous, cards: cards)
            t.expectEqual(cursor.press(.previous, cards: cards), .none, "already at the first")
            t.expectEqual(cursor.press(.markRead, cards: cards), .none, "a permission is not read away")
        },

        TestCase("The keys that need a hand are there and do nothing yet") { t in
            let cards = WaitingQueue.cards(sessions: [row("p", .awaiting, ask: PendingAsk(tool: "Bash", detail: "ls"))],
                                           suggestions: [], now: at(5))
            var cursor = WaitingQueue.Cursor()
            for key in [WaitingQueue.Key.allow, .always, .deny, .reply, .option(1)] {
                t.expectEqual(cursor.press(key, cards: cards), .unavailable, "\(key)")
            }
        },

        TestCase("An ask the panel holds is a permission card, first, with its call") { t in
            let cards = WaitingQueue.cards(sessions: [row("p", .working), row("f", .failed)], suggestions: [],
                                           asks: [held("p", "toolu_1", at: 3)], now: at(5))
            t.expectEqual(kinds(cards), [.permission, .failed])
            t.expectEqual(cards.first?.call, "toolu_1")
            t.expectEqual(cards.first?.sessionIds, ["p"])
            t.expectEqual(cards.first?.title, "p", "the session's name")
            t.expectEqual(cards.first?.line, "Bash: npm publish")
            t.expectEqual(cards.first?.appearedAt, at(3))
            let stranger = WaitingQueue.cards(sessions: [], suggestions: [], asks: [held("gone", "toolu_2")], now: at(5))
            t.expectEqual(stranger.first?.title, "A session", "one the panel does not show is still asked about")
        },

        TestCase("Allow and Deny answer an ask the panel holds; Always does not") { t in
            let cards = WaitingQueue.cards(sessions: [row("p", .working)], suggestions: [], asks: [held("p", "toolu_1")], now: at(5))
            var cursor = WaitingQueue.Cursor()
            t.expectEqual(cursor.press(.allow, cards: cards), .answer(sessionId: "p", call: "toolu_1", .allow))
            t.expectEqual(cursor.press(.deny, cards: cards), .answer(sessionId: "p", call: "toolu_1", .deny))
            t.expectEqual(cursor.press(.always, cards: cards), .unavailable, "the mod can say allow, not always")
            t.expectEqual(cursor.press(.open, cards: cards), .open(sessionId: "p"))
        },

        TestCase("An ask the panel held that left unanswered went back to the terminal") { t in
            let before = WaitingQueue.cards(sessions: [row("p", .working)], suggestions: [], asks: [held("p", "toolu_1")], now: at(5))
            let after = WaitingQueue.cards(sessions: [row("p", .awaiting)], suggestions: [], now: at(60))
            t.expectEqual(WaitingQueue.resolvedElsewhere(before: before, after: after, actedOn: []), [],
                          "answered from the panel by another door: nothing to say")
            let gone = WaitingQueue.resolvedElsewhere(before: before, after: after, actedOn: [],
                                                      returned: [WaitingQueue.heldKey(session: "p", call: "toolu_1")])
            t.expectEqual(gone.map(\.call), ["toolu_1"])
            t.expectEqual(gone.first.map(WaitingQueue.resolvedLine), "Back to the terminal's dialog")
            let answered = WaitingQueue.cards(sessions: [row("q", .awaiting)], suggestions: [], now: at(5))
            t.expectEqual(answered.first.map(WaitingQueue.resolvedLine), "Answered in the terminal")
        },

        TestCase("The selection follows its card when the queue changes, and stays in range") { t in
            let before = WaitingQueue.cards(sessions: [row("a", .failed), row("b", .failed, since: 1), row("c", .failed, since: 2)],
                                            suggestions: [], now: at(5))
            var cursor = WaitingQueue.Cursor(selected: 1)
            let after = WaitingQueue.cards(sessions: [row("b", .failed, since: 1), row("c", .failed, since: 2)], suggestions: [], now: at(6))
            cursor.follow(from: before, to: after)
            t.expectEqual(after[cursor.selected].sessionIds, ["b"], "still on b")
            cursor.follow(from: after, to: [])
            t.expectEqual(cursor.selected, 0)
        },

        TestCase("With a subagent alive, a finished or failed parent is blue, and not in the queue") { t in
            let busy = { (status: SessionStatus) in
                row("p", status).withSubagent(id: "agent-1", starting: true, at: at(0))
            }
            t.expect(WaitingQueue.cards(sessions: [busy(.ready), busy(.failed)], suggestions: [], now: at(5)).isEmpty,
                     "the row shows waiting, so does the queue")
            t.expectEqual(kinds(WaitingQueue.cards(sessions: [busy(.awaiting)], suggestions: [], now: at(5))), [.permission])
        },

        TestCase("A second ask in the same session is a new card, armed anew") { t in
            let first = WaitingQueue.cards(sessions: [row("p", .awaiting, ask: PendingAsk(tool: "Bash", detail: "ls"))],
                                           suggestions: [], now: at(5))
            let second = WaitingQueue.cards(sessions: [row("p", .awaiting, ask: PendingAsk(tool: "Bash", detail: "rm -rf build"))],
                                            suggestions: [], now: at(9))
            t.expect(first[0].id != second[0].id, "different ids")
            var arming = WaitingQueue.Arming()
            arming.update(first, now: at(5))
            t.expect(arming.isArmed(first[0], now: at(9)), "the first, long shown")
            arming.update(second, now: at(9))
            t.expect(!arming.isArmed(second[0], now: at(9.3)), "the second, just shown")
            t.expect(arming.isArmed(second[0], now: at(9.6)), "armed after 600 ms")
        },

        TestCase("A card is armed from when the queue shows it, whatever the session's age") { t in
            let old = WaitingQueue.cards(sessions: [row("p", .awaiting, since: 0)], suggestions: [], now: at(3_600))
            var arming = WaitingQueue.Arming()
            t.expect(!arming.isArmed(old[0], now: at(3_600)), "never shown")
            arming.update(old, now: at(3_600))
            t.expect(!arming.isArmed(old[0], now: at(3_600.5)), "an hour-old ask, shown half a second ago")
        },

        TestCase("The next card to arm is the earliest still unarmed") { t in
            let one = WaitingQueue.cards(sessions: [row("a", .failed)], suggestions: [], now: at(0))
            let two = WaitingQueue.cards(sessions: [row("a", .failed), row("b", .failed, since: 1)], suggestions: [], now: at(0.3))
            var arming = WaitingQueue.Arming()
            arming.update(one, now: at(0))
            arming.update(two, now: at(0.3))
            t.expectEqual(arming.nextArming(after: at(0.4)), at(0.6), "a arms first")
            t.expectEqual(arming.nextArming(after: at(0.7)), at(0.9), "then b")
            t.expectNil(arming.nextArming(after: at(1)), "all armed")
        },

        TestCase("A new answer joining the group re-arms it, and keeps its place") { t in
            let three = WaitingQueue.cards(sessions: [row("r1", .ready), row("r2", .ready, since: 1), row("r3", .ready, since: 2)],
                                           suggestions: [], now: at(5))
            let four = WaitingQueue.cards(sessions: [row("r1", .ready), row("r2", .ready, since: 1), row("r3", .ready, since: 2),
                                                     row("r4", .ready, since: 6)], suggestions: [], now: at(7))
            t.expectEqual(three[0].id, four[0].id, "the same card for the selection")
            var arming = WaitingQueue.Arming()
            arming.update(three, now: at(5))
            arming.update(four, now: at(7))
            t.expect(!arming.isArmed(four[0], now: at(7.2)), "r4 was never seen")
        },

        TestCase("A stuck card dates from when the tool became stuck") { t in
            let cards = WaitingQueue.cards(sessions: [row("w", .working, tool: RunningTool(tool: "Bash", detail: "make", since: at(60)))],
                                           suggestions: [], now: at(20 * 60))
            t.expectEqual(cards.first?.appearedAt, at(60 + 15 * 60))
        },

        TestCase("Only an ask that left is resolved elsewhere: not answers growing into a group, not a stuck tool ending") { t in
            let two = WaitingQueue.cards(sessions: [row("r1", .ready), row("r2", .ready, since: 1)], suggestions: [], now: at(5))
            let three = WaitingQueue.cards(sessions: [row("r1", .ready), row("r2", .ready, since: 1), row("r3", .ready, since: 2)],
                                           suggestions: [], now: at(6))
            t.expect(WaitingQueue.resolvedElsewhere(before: two, after: three, actedOn: []).isEmpty, "grouped, not resolved")
            let stuck = WaitingQueue.cards(sessions: [row("w", .working, tool: RunningTool(tool: "Bash", detail: "make", since: at(0)))],
                                           suggestions: [], now: at(20 * 60))
            t.expect(WaitingQueue.resolvedElsewhere(before: stuck, after: [], actedOn: []).isEmpty, "the tool ended")
        },

        TestCase("Four cards are drawn, around the one selected, and the rest are counted") { t in
            t.expectEqual(WaitingQueue.window(count: 3, selected: 0), 0..<3, "all of a short queue")
            t.expectEqual(WaitingQueue.window(count: 9, selected: 0), 0..<4)
            t.expectEqual(WaitingQueue.window(count: 9, selected: 5), 2..<6, "the selected one is always drawn")
            t.expectEqual(WaitingQueue.window(count: 9, selected: 8), 5..<9)
            t.expectEqual(WaitingQueue.window(count: 0, selected: 0), 0..<0)
        },

        TestCase("A card gone without the panel acting on it was resolved elsewhere") { t in
            let before = WaitingQueue.cards(sessions: [
                row("p", .awaiting, ask: PendingAsk(tool: "Bash", detail: "ls")), row("q", .awaiting, since: 1),
            ], suggestions: [], now: at(5))
            let after = WaitingQueue.cards(sessions: [], suggestions: [], now: at(6))
            let elsewhere = WaitingQueue.resolvedElsewhere(before: before, after: after, actedOn: [before[1].id])
            t.expectEqual(elsewhere.map(\.sessionIds), [["p"]])
            t.expectEqual(WaitingQueue.resolvedElsewhere(before: before, after: before, actedOn: []), [], "still there")
        },
    ])
}
