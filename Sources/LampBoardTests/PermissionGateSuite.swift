import LampBoardCore
import Foundation
import TestKit

/// Allow and Deny from the panel (D73, AD1): what a session's mod asks, how
/// long the panel has to answer, and how many asks may wait at once.
enum PermissionGateSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private static let session = "5f0c2a7e-1b3d-4c8e-9a6f-2d4b8e1c7a90"

    private static func ask(_ call: String = "toolu_01AbC", detail: String = "npm publish") -> String {
        #"{"v":1,"session":"\#(session)","id":"\#(call)","tool":"Bash","detail":"\#(detail)"}"#
    }

    private static func request(_ json: String) -> PermissionGate.Request? {
        PermissionGate.decode(Data(json.utf8), at: t0)
    }

    static let suite = TestSuite("Allow and Deny from the panel", [

        TestCase("An ask is read with its session, call, tool and one masked line") { t in
            let read = request(ask(detail: "curl -H 'Authorization: Bearer abc123' https://example.com"))
            t.expectEqual(read?.sessionId, session)
            t.expectEqual(read?.callId, "toolu_01AbC")
            t.expectEqual(read?.tool, "Bash")
            t.expect(read?.line.contains("abc123") == false, "the secret masked: \(read?.line ?? "")")
            t.expectEqual(read?.receivedAt, t0)
        },

        TestCase("A malformed ask is refused, not guessed") { t in
            t.expectNil(request(#"{"v":1,"session":"not a session","id":"toolu_1","tool":"Bash"}"#), "a session id that is not one")
            t.expectNil(request(#"{"v":1,"session":"\#(session)","id":"a b","tool":"Bash"}"#), "a call id with a space")
            t.expectNil(request(#"{"v":2,"session":"\#(session)","id":"toolu_1","tool":"Bash"}"#), "another version")
            t.expectNil(request("{"), "not JSON")
        },

        TestCase("The panel answers within 55 seconds, or the session's own dialog does") { t in
            t.expectEqual(PermissionGate.answerWithin, 55)
            var book = PermissionGate.Book()
            guard let one = request(ask()) else { return t.fail("not read") }
            t.expect(book.add(one), "taken")
            t.expectEqual(book.expired(at: at(54.9)), [], "still the panel's")
            t.expectEqual(book.expired(at: at(55)).map(\.callId), ["toolu_01AbC"], "back to the dialog")
            t.expect(book.pending.isEmpty, "and gone from the book")
        },

        TestCase("An answer is taken once; a late or unknown one changes nothing") { t in
            var book = PermissionGate.Book()
            guard let one = request(ask()) else { return t.fail("not read") }
            _ = book.add(one)
            t.expectEqual(book.answer(session: session, call: "toolu_01AbC", .allow), .allow)
            t.expectNil(book.answer(session: session, call: "toolu_01AbC", .deny), "already answered")
            t.expectNil(book.answer(session: session, call: "toolu_unknown", .allow), "never asked")
        },

        TestCase("One ask per call, and no more than eight waiting") { t in
            var book = PermissionGate.Book()
            guard let one = request(ask()) else { return t.fail("not read") }
            t.expect(book.add(one), "the first")
            t.expect(!book.add(one), "the same call twice")
            for i in 1..<PermissionGate.pendingMax {
                guard let next = request(ask("toolu_\(i)")) else { return t.fail("not read \(i)") }
                t.expect(book.add(next), "\(i)")
            }
            guard let over = request(ask("toolu_over")) else { return t.fail("not read") }
            t.expect(!book.add(over), "the ninth goes to the dialog at once")
        },

        TestCase("The proof is HMAC-SHA256, as RFC 4231 computes it") { t in
            t.expectEqual(PermissionGate.mac(key: "Jefe", message: "what do ya want for nothing?"),
                          "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        },

        TestCase("An ask is the mod's only if its proof is the key's; the answer is signed back") { t in
            let key = String(repeating: "a1", count: 32)
            let nonce = "0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D"
            let proof = PermissionGate.mac(key: key, message: PermissionGate.askMessage(nonce: nonce, session: session, call: "toolu_01AbC"))
            t.expect(PermissionGate.isGenuine(key: key, nonce: nonce, proof: proof, session: session, call: "toolu_01AbC"), "the key's own proof")
            t.expect(!PermissionGate.isGenuine(key: key, nonce: nonce, proof: proof, session: session, call: "toolu_other"),
                     "the proof is for one call")
            t.expect(!PermissionGate.isGenuine(key: String(repeating: "b2", count: 32), nonce: nonce, proof: proof, session: session, call: "toolu_01AbC"),
                     "another key")
            t.expectEqual(PermissionGate.signed(.deny, key: key, nonce: nonce),
                          "deny " + PermissionGate.mac(key: key, message: "answer:\(nonce):deny"))
        },

        TestCase("Answers are addressed by session and call, not by call alone") { t in
            var book = PermissionGate.Book()
            guard let one = request(ask()) else { return t.fail("not read") }
            _ = book.add(one)
            t.expectNil(book.answer(session: "e5f6a7b8-0000-4000-8000-000000000002", call: "toolu_01AbC", .allow), "another session")
            t.expectEqual(book.answer(session: session, call: "toolu_01AbC", .allow), .allow)
        },

        TestCase("The same call id from another session is another ask") { t in
            var book = PermissionGate.Book()
            let other = #"{"v":1,"session":"e5f6a7b8-0000-4000-8000-000000000002","id":"toolu_01AbC","tool":"Bash"}"#
            guard let one = request(ask()), let two = request(other) else { return t.fail("not read") }
            t.expect(book.add(one), "the first session's")
            t.expect(book.add(two), "the second's, though the id is the same")
            t.expectEqual(book.pending.count, 2)
        },

        TestCase("The verdict the mod receives is one of three words") { t in
            t.expectEqual(PermissionGate.Verdict.allow.rawValue, "allow")
            t.expectEqual(PermissionGate.Verdict.deny.rawValue, "deny")
            t.expectEqual(PermissionGate.Verdict.ask.rawValue, "ask")
        },
    ])
}
