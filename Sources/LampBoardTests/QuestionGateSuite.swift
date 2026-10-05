import LampBoardCore
import Foundation
import TestKit

/// A session's question answered from the panel (D86): what the mod puts, how
/// it is proven, how the choice goes back, and how the queue shows it.
enum QuestionGateSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let session = "5f0c2a7e-1b3d-4c8e-9a6f-2d4b8e1c7a90"
    private static let key = String(repeating: "a1", count: 32)
    private static let nonce = "0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D"

    private static func body(_ options: [String], question: String = "Which color do you prefer?") -> Data {
        let object: [String: Any] = ["v": 1, "session": session, "id": "toolu_01Q", "question": question,
                                     "header": "Color", "options": options]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static let suite = TestSuite("A session's question, answered from the panel", [

        TestCase("A question is read with its session, call, words and two to four options") { t in
            let read = QuestionGate.decode(body(["Red", "Blue"]), at: t0)
            t.expectEqual(read?.sessionId, session)
            t.expectEqual(read?.callId, "toolu_01Q")
            t.expectEqual(read?.line, "Which color do you prefer?")
            t.expectEqual(read?.options, ["Red", "Blue"])
            t.expectEqual(read?.tool, "AskUserQuestion")
            t.expectNil(QuestionGate.decode(body(["Only"]), at: t0), "one option is no choice")
            t.expectNil(QuestionGate.decode(body(["a", "b", "c", "d", "e"]), at: t0), "five do not fit a card")
            t.expectNil(QuestionGate.decode(body(["Red", "Red"]), at: t0), "two the same cannot be told apart")
            t.expectNil(QuestionGate.decode(body(["Red", "Blue"], question: " "), at: t0), "no question")
        },

        TestCase("Its words are one clean line and its options short ones") { t in
            let read = QuestionGate.decode(body(["Re\u{202E}d", String(repeating: "x", count: 90)], question: "Pick\none"), at: t0)
            t.expectEqual(read?.line, "Pick one")
            t.expect(read?.options.first?.unicodeScalars.contains { $0.value == 0x202E } == false, "no override")
            t.expect((read?.options.last?.count ?? 99) <= QuestionGate.optionLimit, "cut")
        },

        TestCase("Proven like a permission, under its own prefix; the choice goes back signed") { t in
            let proof = PermissionGate.mac(key: key, message: QuestionGate.askMessage(nonce: nonce, session: session, call: "toolu_01Q"))
            t.expect(QuestionGate.isGenuine(key: key, nonce: nonce, proof: proof, session: session, call: "toolu_01Q"), "its own proof")
            let permission = PermissionGate.mac(key: key, message: PermissionGate.askMessage(nonce: nonce, session: session, call: "toolu_01Q"))
            t.expect(!QuestionGate.isGenuine(key: key, nonce: nonce, proof: permission, session: session, call: "toolu_01Q"),
                     "a permission's proof is not a question's")
            t.expectEqual(QuestionGate.signed(choice: 1, key: key, nonce: nonce),
                          "choose 1 " + PermissionGate.mac(key: key, message: "choose:\(nonce):1"))
            t.expectEqual(QuestionGate.signed(choice: nil, key: key, nonce: nonce),
                          "ask " + PermissionGate.mac(key: key, message: "answer:\(nonce):ask"))
        },

        TestCase("A question goes back to its dialog at 20 seconds, a permission at 55") { t in
            var book = PermissionGate.Book()
            guard let asked = QuestionGate.decode(body(["Red", "Blue"]), at: t0),
                  let permission = PermissionGate.decode(Data(#"{"v":1,"session":"\#(session)","id":"toolu_P","tool":"Bash"}"#.utf8), at: t0)
            else { return t.fail("not read") }
            _ = book.add(asked); _ = book.add(permission)
            t.expectEqual(QuestionGate.answerWithin, 20)
            t.expectEqual(book.expired(at: t0.addingTimeInterval(20)).map(\.callId), ["toolu_01Q"], "the question's time is up")
            t.expectEqual(book.pending.map(\.callId), ["toolu_P"], "the permission still waits")
        },

        TestCase("A held question is a question card with its options; a digit chooses one") { t in
            guard let asked = QuestionGate.decode(body(["Red", "Blue"]), at: t0) else { return t.fail("not read") }
            let cards = WaitingQueue.cards(sessions: [], suggestions: [], asks: [asked], now: t0)
            t.expectEqual(cards.first?.kind, .question)
            t.expectEqual(cards.first?.options, ["Red", "Blue"])
            var cursor = WaitingQueue.Cursor()
            t.expectEqual(cursor.press(.option(2), cards: cards), .choose(sessionId: session, call: "toolu_01Q", index: 1))
            t.expectEqual(cursor.press(.option(3), cards: cards), .unavailable, "no third option")
            t.expectEqual(cursor.press(.allow, cards: cards), .unavailable, "a question is not allowed, it is answered")
        },
    ])
}
