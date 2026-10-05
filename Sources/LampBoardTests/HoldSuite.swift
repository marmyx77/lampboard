import LampBoardCore
import Foundation
import TestKit

/// Away, a risky command is held (§5.8, A2): one the engine would run on its own,
/// that deletes, force-pushes or runs as root, waits for the person instead of
/// running while nobody is there.
enum HoldSuite {

    static let suite = TestSuite("Held while away", [

        TestCase("Away, a destructive command is held with what it does, on any line; here or harmless, it goes") { t in
            t.expectEqual(HoldExchange.reason(command: "rm -rf build/", cut: false, away: true),
                          "Held while you are away: this command deletes recursively. It waits for you.")
            t.expectNil(HoldExchange.reason(command: "rm -rf build/", cut: false, away: false), "here: it goes")
            t.expectNil(HoldExchange.reason(command: "npm test", cut: false, away: true), "harmless: it goes")
            t.expectEqual(HoldExchange.reason(command: "echo ok\nrm -rf ~/proj", cut: false, away: true),
                          "Held while you are away: this command deletes recursively. It waits for you.", "the second line read too")
            t.expectNotNil(HoldExchange.reason(command: "echo authorization: rm -rf x", cut: false, away: true),
                           "judged unmasked: a mask cannot swallow it")
            t.expectNotNil(HoldExchange.reason(command: "npm test", cut: true, away: true), "too long to read whole: held")
        },

        TestCase("The mod is heard only proven for its session and command; the answer is signed") { t in
            let key = String(repeating: "ab", count: 16), nonce = "0123456789abcdef0123"
            let session = "e2e0d0d0-0000-4000-8000-0000000000aa", command = "git push --force"
            let body = Data(#"{"v":1,"session":"\#(session)","command":"\#(command)","cut":true}"#.utf8)
            let proof = PermissionGate.mac(key: key, message: HoldExchange.proofMessage(nonce: nonce, session: session, cut: true, command: command))
            t.expectEqual(HoldExchange.provenRequest(body, nonce: nonce, proof: proof, key: key),
                          HoldExchange.Request(session: session, command: command, cut: true))
            t.expectNil(HoldExchange.provenRequest(body, nonce: nonce, proof: nil, key: key))
            let uncut = PermissionGate.mac(key: key, message: HoldExchange.proofMessage(nonce: nonce, session: session, cut: false, command: command))
            t.expectNil(HoldExchange.provenRequest(body, nonce: nonce, proof: uncut, key: key), "the cut is proven too")
            t.expectEqual(HoldExchange.answer(reason: nil, nonce: nonce, key: key),
                          "go " + PermissionGate.mac(key: key, message: "hold:\(nonce):go:"))
            t.expect(HoldExchange.answer(reason: "held", nonce: nonce, key: key).hasSuffix("\nheld"), "the sentence after the head")
        },
    ])
}
