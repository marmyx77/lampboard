#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LampBoardCore

// Prints the relay's test vectors as one JSON document on standard output.
//
// Everything here goes through the Core's public API: the envelopes are sealed
// by `PushEnvelope.seal`, the requests built and checked by
// `RelayPushRequest.make`, the wire encoded by `V1Codec`. Nothing is written by
// hand except the inputs, and the inputs are fiction (example names, a token of
// one repeated byte).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("relay vectors: \(message)\n".utf8))
    exit(1)
}

func json(_ value: some Encodable) -> Any {
    guard let data = try? V1Codec.encoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) else { fail("could not encode \(value)") }
    return object
}

// Fixed keys, so that the vectors say which pair they belong to. The sealing
// itself draws a fresh nonce on every run: the envelope bytes change, their form
// does not.
guard let sourceKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32)),
      let deviceKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32)),
      let key = try? PushEnvelope.key(mine: sourceKey, theirs: deviceKey.publicKey, source: "node-1", device: "phone-1")
else { fail("no key") }

let at = Date(timeIntervalSince1970: 1_760_000_000)
let token = String(repeating: "ab", count: 32)
let liveToken = String(repeating: "cd", count: 40)
let capability = RelayCapability(cap: "c2lnbmVkLWJ5LXRoZS1yZWxheQ==", token: token, environment: .sandbox)
let liveCapability = RelayCapability(cap: "c2lnbmVkLWJ5LXRoZS1yZWxheS1sYQ==", token: liveToken, environment: .sandbox)

func content(_ title: String, _ body: String, seq: Int, session: String? = "00000000-0000-4000-8000-000000000001") -> PushContent {
    PushContent(source: "Example Node", journal: "journal-a", seq: seq, at: at, title: title, body: body, session: session)
}

struct Case {
    let name: String
    let capability: RelayCapability
    let kind: PushKind
    let urgent: Bool
    let content: PushContent
}

let sendable: [Case] = [
    Case(name: "alert-permission", capability: capability, kind: .alert, urgent: true,
         content: content("project-alpha", "A session is asking to run a command", seq: 1)),
    Case(name: "alert-turn-done", capability: capability, kind: .alert, urgent: false,
         content: content("project-alpha", "The turn is done", seq: 2)),
    Case(name: "background-counts", capability: capability, kind: .background, urgent: false,
         content: content("counts", "amber 1 red 0 green 2", seq: 3, session: nil)),
    Case(name: "liveactivity-counts", capability: liveCapability, kind: .liveactivity, urgent: false,
         content: content("counts", "amber 1 red 0 green 2", seq: 4, session: nil)),
]

var requests: [[String: Any]] = []
for item in sendable {
    guard let sealed = try? PushEnvelope.seal(item.content, with: key) else { fail("could not seal \(item.name)") }
    guard PushEnvelope.open(sealed, with: key) == item.content else { fail("\(item.name) does not open") }
    do {
        let request = try RelayPushRequest.make(
            capability: item.capability, kind: item.kind, urgent: item.urgent, sealed: sealed, content: item.content)
        requests.append(["name": item.name, "request": json(request),
                         "secrets": [item.content.title, item.content.body, item.content.session ?? ""].filter { !$0.isEmpty }])
    } catch {
        fail("the Core refused \(item.name): \(error)")
    }
}

// What the Core refuses to send, and the bytes it refused: the relay must
// refuse them too, should a source without the Core's check send them.
func refusal(_ name: String, kind: PushKind, urgent: Bool, sealed: String, content: PushContent) -> [String: Any] {
    do {
        _ = try RelayPushRequest.make(capability: capability, kind: kind, urgent: urgent, sealed: sealed, content: content)
        fail("the Core sent \(name)")
    } catch let refusal as RelayPushRequest.Refusal {
        // The request as a source without the check would have sent it.
        let wire: [String: Any] = ["cap": capability.cap, "token": capability.token,
                                   "environment": capability.environment.rawValue, "kind": kind.rawValue,
                                   "priority": urgent ? 10 : 5, "envelope": sealed]
        return ["name": name, "coreRefusal": "\(refusal)", "request": wire]
    } catch {
        fail("\(name): \(error)")
    }
}

let withPath = content("project-alpha", "Edit /Users/dev/project-alpha/Sources/Secret.swift", seq: 5)
guard let unsealedPlain = try? V1Codec.encoder().encode(withPath) else { fail("no plain content") }
guard let goodSealed = try? PushEnvelope.seal(withPath, with: key) else { fail("no seal") }
let refused: [[String: Any]] = [
    refusal("plaintext-path", kind: .alert, urgent: false, sealed: unsealedPlain.base64EncodedString(), content: withPath),
    refusal("too-large", kind: .alert, urgent: false,
            sealed: Data((0..<2400).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).base64EncodedString(), content: withPath),
    refusal("background-urgent", kind: .background, urgent: true, sealed: goodSealed, content: withPath),
]

let registration = V1PushRegistration(
    capability: capability.cap, token: token, environment: .sandbox,
    envelopeKey: deviceKey.publicKey.rawRepresentation.base64EncodedString(), liveActivityToken: liveToken)
guard registration.problem == nil else { fail("registration: \(registration.problem ?? "")") }

let document: [String: Any] = [
    "generatedBy": "relay/vectors (LampBoardCore)",
    "envelopeMaxBytes": PushEnvelope.maxBytes,
    "envelopeVersion": PushEnvelope.version,
    "capability": json(capability),
    "registration": json(registration),
    "requests": requests,
    "refused": refused,
    "envelopeKeys": [
        "sourcePrivate": sourceKey.rawRepresentation.base64EncodedString(),
        "devicePublic": deviceKey.publicKey.rawRepresentation.base64EncodedString(),
        "source": "node-1", "device": "phone-1",
    ],
]
guard let out = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
else { fail("could not write the document") }
FileHandle.standardOutput.write(out)
FileHandle.standardOutput.write(Data("\n".utf8))
