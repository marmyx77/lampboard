import CryptoKit
import Foundation
import LampBoardCore
import TestKit

/// The Hub's command channel (D152), against the real app: the panel proves it
/// holds its key, a command waits signed for its session, is collected once,
/// and opens only with the public key the mod reads.
enum TrustE2ESuite {

    private static let session = "5e2c8a71-4b3d-4f6e-9a1c-2d7b8e9f0a13"
    private static let other = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    private static func publicKey(_ app: AppUnderTest) -> Curve25519.Signing.PublicKey? {
        let url = app.home.appendingPathComponent(".lampboard/panel-key.pub")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let raw = CommandEnvelope.bytes(fromHex: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · the Hub's signed commands", [

            TestCase("the panel's public key is on disk for the mod, and its private half is not readable by others") { a in
                a.expectNotNil(publicKey(app), "panel-key.pub holds a key")
                let pub = try? FileManager.default.attributesOfItem(atPath: app.home.appendingPathComponent(".lampboard/panel-key.pub").path)
                a.expectEqual((pub?[.posixPermissions] as? NSNumber)?.intValue, 0o644, "the public half is 0644")
                let priv = try? FileManager.default.attributesOfItem(atPath: app.home.appendingPathComponent(".lampboard/panel-key").path)
                a.expectEqual((priv?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the fake home's private half is 0600")
            },

            TestCase("the panel's hello is its key's signature of the mod's nonce") { a in
                let nonce = "0123456789abcdef-hello"
                let result = app.raw(method: "GET", path: AppConfig.modHelloPath, headers: ["X-LampBoard-Nonce": nonce])
                a.expectEqual(result.status, 200, result.body)
                guard let object = try? JSONSerialization.jsonObject(with: Data(result.body.utf8)) as? [String: String],
                      let sig = object["sig"].flatMap(CommandEnvelope.bytes(fromHex:)), let key = publicKey(app)
                else { return a.fail("no hello: \(result.body)") }
                a.expectEqual(object["pub"], CommandEnvelope.hex(key.rawRepresentation), "the key on disk")
                a.expect(key.isValidSignature(sig, for: Data("lampboard-hello:\(nonce)".utf8)), "a signature of the nonce")
                a.expect(!key.isValidSignature(sig, for: Data("lampboard-hello:someone-else-nonce".utf8)), "of that nonce only")
            },

            TestCase("the hello and the inbox are refused without the token, and a bad nonce gets nothing") { a in
                a.expectEqual(app.raw(method: "GET", path: AppConfig.modHelloPath, token: .some(nil), headers: ["X-LampBoard-Nonce": "0123456789abcdef"]).status, 401)
                a.expectEqual(app.raw(method: "GET", path: AppConfig.modInboxPath, token: .some(nil), headers: ["X-LampBoard-Session": session]).status, 401)
                a.expectEqual(app.raw(method: "GET", path: AppConfig.modHelloPath, headers: ["X-LampBoard-Nonce": "short"]).status, 400)
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modHelloPath, headers: ["X-LampBoard-Nonce": "0123456789abcdef"]).status, 405)
            },

            TestCase("a command waits signed for its session, opens with the key on disk, and is collected once") { a in
                let sent = app.raw(method: "POST", path: AppConfig.hubSendPath,
                                   body: #"{"session":"\#(session)","op":"submit","args":{"text":"run the tests","asUser":"true"}}"#)
                a.expectEqual(sent.status, 204, sent.body)
                let elsewhere = app.raw(method: "GET", path: AppConfig.modInboxPath, headers: ["X-LampBoard-Session": other])
                a.expectEqual(elsewhere.body, "[]", "another session collects nothing")
                let first = app.raw(method: "GET", path: AppConfig.modInboxPath, headers: ["X-LampBoard-Session": session])
                guard let list = try? JSONDecoder().decode([CommandEnvelope].self, from: Data(first.body.utf8)), list.count == 1,
                      let key = publicKey(app)
                else { return a.fail("no command: \(first.status) \(first.body)") }
                switch CommandEnvelope.open(list[0], publicKey: key, session: session) {
                case .success(let payload):
                    a.expectEqual(payload.op, "submit")
                    a.expectEqual(payload.args["text"], "run the tests")
                    a.expectEqual(payload.args["asUser"], "true")
                case .failure(let refusal):
                    a.fail("the mod would refuse it: \(refusal)")
                }
                a.expectEqual(CommandEnvelope.open(list[0], publicKey: key, session: other), .failure(.otherSession), "and only for its session")
                let again = app.raw(method: "GET", path: AppConfig.modInboxPath, headers: ["X-LampBoard-Session": session])
                a.expectEqual(again.body, "[]", "collected once")
            },

            TestCase("a command the panel would not sign is not queued") { a in
                let bad = app.raw(method: "POST", path: AppConfig.hubSendPath, body: #"{"session":"not a session","op":"submit","args":{}}"#)
                a.expectEqual(bad.status, 400, "a session id that is not one")
            },
        ])
    }
}
