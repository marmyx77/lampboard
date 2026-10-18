import LampBoardCore
import Foundation
import TestKit

/// The battery every `v1` source must pass, spoken over a byte stream (§2.2 of
/// the mobile plan, "one protocol, two sources").
///
/// It writes its requests by hand and reads the replies as plain JSON, framed by
/// a reader of its own: nothing here goes through the Core's encoder or decoder,
/// so a defect shared by both ends of the Core cannot hide from it. What it
/// holds the replies to is `V1WireContract`.
///
/// Run today against the reference source in memory; meant to run, unchanged,
/// against `lampd` in the fake node over a real ssh, and against the Mac's own
/// server. The bite: a field renamed in one source's encoder turns this red for
/// that source (`Scripts/bite.sh`).
public enum V1Conformance {

    public static func suite(against target: V1ConformanceTarget) -> TestSuite {
        TestSuite("v1 conformance: \(target.name)", cases(target))
    }

    /// Generous for a loopback, which waits on a clock of its own; enough for
    /// ssh on a LAN.
    static let patience: TimeInterval = 5

    static func cases(_ target: V1ConformanceTarget) -> [TestCase] {
        [
            TestCase("hello answers first, and says what the source is and how old its state is") { t in
                withWire(target, t) { wire in
                    let hello = try wire.ask(["op": "hello", "protocol": 1, "client": "conformance"], expecting: "hello")
                    t.expectEqual(hello?["re"] as? Int, wire.lastId, "it answers its request")
                    t.expect((hello?["minClient"] as? Int ?? 99) <= 1, "it answers a protocol-1 client")
                    t.expect((hello?["stateAge"] as? [String: Any])?["seq"] is Int, "the age names the journal point")
                }
            },

            TestCase("Nothing but hello is answered before hello") { t in
                withWire(target, t) { wire in
                    let refusal = try wire.ask(["op": "state"], expecting: "error")
                    t.expectEqual(refusal?["code"] as? String, "helloFirst", "refused")
                }
            },

            TestCase("The state holds rows that keep the contract") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    let state = try wire.ask(["op": "state"], expecting: "state")
                    let rows = state?["rows"] as? [[String: Any]]
                    t.expect(rows.map { !$0.isEmpty } ?? false, "the target has rows to show")
                    t.expect(state?["journal"] is String, "it names its journal")
                }
            },

            TestCase("Holding nothing: the acknowledgement, the state, then each change as an event") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    let ack = try wire.ask(["op": "events", "ping": target.pingInterval], expecting: "events")
                    t.expectEqual(ack?["resync"] as? Bool, true, "a resync")
                    let state = try wire.wait(for: "state")
                    let start = state?["seq"] as? Int ?? -1
                    try target.provoke(3)
                    let events = try wire.collect("event", count: 3)
                    t.expectEqual(events.compactMap { $0["seq"] as? Int }, [start + 1, start + 2, start + 3], "numbered after the state")
                }
            },

            TestCase("Coming back with since: exactly the events after it, once each") { t in
                var journal = "", held = 0
                withWire(target, t) { wire in
                    try wire.greet()
                    _ = try wire.ask(["op": "events", "ping": target.pingInterval], expecting: "events")
                    let state = try wire.wait(for: "state")
                    journal = state?["journal"] as? String ?? ""
                    held = state?["seq"] as? Int ?? 0
                }
                // Gone while the source goes on.
                try? target.provoke(4)
                withWire(target, t) { wire in
                    try wire.greet()
                    let ack = try wire.ask(["op": "events", "since": held, "journal": journal, "ping": target.pingInterval],
                                           expecting: "events")
                    t.expectEqual(ack?["resync"] as? Bool, false, "the journal reaches back")
                    t.expectEqual(ack?["replayed"] as? Int, 4, "four to replay")
                    let replay = try wire.collect("event", count: 4)
                    t.expectEqual(replay.compactMap { $0["seq"] as? Int }, Array((held + 1)...(held + 4)), "in order, no hole")
                    let ping = try wire.wait(for: "ping")
                    t.expectEqual(ping?["seq"] as? Int, held + 4, "and nothing twice: the ping is at the last one")
                }
            },

            TestCase("Numbers from another journal bring a whole state") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    let ack = try wire.ask(["op": "events", "since": 1, "journal": "a-journal-that-never-was",
                                            "ping": target.pingInterval], expecting: "events")
                    t.expectEqual(ack?["resync"] as? Bool, true, "resync")
                    t.expect(try wire.wait(for: "state") != nil, "the state follows")
                }
            },

            TestCase("A ping every interval, at the last number sent") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    _ = try wire.ask(["op": "events", "ping": target.pingInterval], expecting: "events")
                    let seq = try wire.wait(for: "state")?["seq"] as? Int
                    let pings = try wire.collect("ping", count: 2)
                    t.expectEqual(pings.count, 2, "two pings")
                    t.expect(pings.allSatisfy { $0["seq"] as? Int == seq }, "at the state's number")
                }
            },

            TestCase("A low-power action is done; anything else is refused by name") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    let rows = try wire.ask(["op": "state"], expecting: "state")?["rows"] as? [[String: Any]] ?? []
                    guard let id = rows.first?["id"] as? String else { t.expect(false, "no row to act on"); return }
                    let done = try wire.ask(["op": "cmd", "action": "markSeen", "session": id], expecting: "result")
                    t.expectEqual(done?["op"] as? String, "cmd", "done")
                    let allow = try wire.ask(["op": "cmd", "action": "allow", "session": id], expecting: "error")
                    t.expectEqual(allow?["code"] as? String, "badRequest", "no allow through the read key (R4)")
                    let shell = try wire.ask(["op": "exec", "command": "id"], expecting: "error")
                    t.expectEqual(shell?["code"] as? String, "unknownOp", "no op outside the list")
                    t.expect(try wire.ask(["op": "state"], expecting: "state") != nil, "and the connection goes on")
                }
            },

            TestCase("push.register: the source's half of the envelope key, or a refusal by name") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    // A public key of the right length: 32 bytes of example.
                    let key = Data(repeating: 9, count: 32).base64EncodedString()
                    let token = String(repeating: "ab", count: 32)
                    let bad = try wire.ask(["op": "push.register", "capability": "Y2Fw", "token": "not hex",
                                            "environment": "sandbox", "envelopeKey": key], expecting: "error")
                    t.expectEqual(bad?["code"] as? String, "badRequest", "a token that is not one")
                    let answer = try wire.ask(["op": "push.register", "capability": "Y2Fw", "token": token,
                                               "environment": "sandbox", "envelopeKey": key,
                                               "preferences": ["finished": true]], expecting: ["result", "error"])
                    if answer?["type"] as? String == "error" {
                        t.expectEqual(answer?["code"] as? String, "unavailable", "a source that sends nothing says so")
                    } else {
                        let push = answer?["push"] as? [String: Any]
                        let half = (push?["envelopeKey"] as? String).flatMap { Data(base64Encoded: $0) }
                        t.expectEqual(half?.count, 32, "an X25519 public key")
                        t.expect((push?["device"] as? String)?.isEmpty == false, "the device's name for the key")
                    }
                }
            },

            TestCase("The devices are refused to the read key") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    let refusal = try wire.ask(["op": "devices", "action": "list"], expecting: "error")
                    t.expectEqual(refusal?["code"] as? String, "forbidden", "forbidden")
                }
            },

            TestCase("A transcript says how much it did not send; a path is not a session") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    let rows = try wire.ask(["op": "state"], expecting: "state")?["rows"] as? [[String: Any]] ?? []
                    for row in rows {
                        guard let id = row["id"] as? String else { continue }
                        let answer = try wire.ask(["op": "transcript", "session": id, "limit": 1],
                                                  expecting: ["transcript", "error"])
                        if answer?["type"] as? String == "transcript" {
                            t.expect(answer?["notSent"] is Int, "notSent is always there")
                        } else {
                            t.expectEqual(answer?["code"] as? String, "notFound", "or there is none")
                        }
                    }
                    let path = try wire.ask(["op": "transcript", "session": "../../.ssh/id_ed25519"], expecting: "error")
                    t.expectEqual(path?["code"] as? String, "badRequest", "refused")
                }
            },

            TestCase("A client below minClient is told so and the stream ends") { t in
                withWire(target, t) { wire in
                    let refusal = try wire.ask(["op": "hello", "protocol": 0, "client": "ancient"], expecting: "error")
                    t.expectEqual(refusal?["code"] as? String, "clientTooOld", "refused")
                    t.expect(try wire.waitForEnd(), "and closed")
                }
            },

            TestCase("Bytes out of step end the stream with a reason") { t in
                withWire(target, t) { wire in
                    try wire.greet()
                    try wire.raw(Array("SSH-2.0-not-a-frame\r\n".utf8))
                    let refusal = try wire.wait(for: "error")
                    t.expectEqual(refusal?["code"] as? String, "badFrame", "said why")
                    t.expect(try wire.waitForEnd(), "and closed")
                }
            },
        ]
    }

    /// Opens a connection, runs `body`, records what went wrong, closes. Every
    /// reply seen on the way is checked against the contract.
    static func withWire(_ target: V1ConformanceTarget, _ t: Assertions, role: V1Role = .read, _ body: (Wire) throws -> Void) {
        let stream: V1ByteStream
        do { stream = try target.connect(role: role) } catch {
            t.expect(false, "could not connect: \(error)")
            return
        }
        defer { stream.close() }
        let wire = Wire(stream, patience: patience)
        do { try body(wire) } catch { t.expect(false, "\(error)") }
        for violation in wire.violations { t.expect(false, "off contract: \(violation)") }
    }
}

/// One conversation, framed and parsed without the Core.
final class Wire {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let stream: V1ByteStream
    private let patience: TimeInterval
    private var buffer: [UInt8] = []
    private var inbox: [[String: Any]] = []
    private var closed = false
    private(set) var lastId = 0
    private(set) var violations: [String] = []

    init(_ stream: V1ByteStream, patience: TimeInterval) {
        self.stream = stream
        self.patience = patience
    }

    func greet() throws {
        guard try ask(["op": "hello", "protocol": 1, "client": "conformance"], expecting: "hello") != nil else {
            throw Failure(description: "no hello")
        }
    }

    /// Sends a request with a fresh id and returns the first reply of one of
    /// `types` answering it, or `nil`.
    func ask(_ request: [String: Any], expecting types: [String]) throws -> [String: Any]? {
        lastId += 1
        var object = request
        object["id"] = lastId
        try send(object)
        let id = lastId
        return try wait { types.contains($0["type"] as? String ?? "") && ($0["re"] as? Int == id || $0["re"] == nil) }
    }

    func ask(_ request: [String: Any], expecting type: String) throws -> [String: Any]? {
        try ask(request, expecting: [type])
    }

    func send(_ object: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try raw(Array("\(json.count) ".utf8) + Array(json) + [0x0A])
    }

    func raw(_ bytes: [UInt8]) throws { try stream.write(bytes) }

    func wait(for type: String) throws -> [String: Any]? {
        try wait { $0["type"] as? String == type }
    }

    /// The next `count` replies of `type`, skipping anything else.
    func collect(_ type: String, count: Int) throws -> [[String: Any]] {
        var found: [[String: Any]] = []
        while found.count < count, let next = try wait(for: type) { found.append(next) }
        return found
    }

    /// `true` once the source has closed the stream.
    func waitForEnd() throws -> Bool {
        let deadline = patience * 2
        var waited: TimeInterval = 0
        while !closed && waited < deadline {
            try fill(0.25)
            waited += 0.25
        }
        return closed
    }

    /// The first reply that satisfies `wanted`, dropping the ones before it.
    private func wait(_ wanted: ([String: Any]) -> Bool) throws -> [String: Any]? {
        var waited: TimeInterval = 0
        while true {
            if let index = inbox.firstIndex(where: wanted) {
                let found = inbox[index]
                inbox.removeFirst(index + 1)
                return found
            }
            if closed || waited >= patience { return nil }
            try fill(0.25)
            waited += 0.25
        }
    }

    private func fill(_ timeout: TimeInterval) throws {
        guard !closed else { return }
        guard let bytes = try stream.read(timeout: timeout) else {
            closed = true
            return
        }
        buffer += bytes
        while let frame = try nextFrame() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(frame))) as? [String: Any] else {
                violations.append("a frame that is not a JSON object")
                continue
            }
            violations += V1WireContract.violations(of: object)
            inbox.append(object)
        }
    }

    /// `<decimal length> <json>\n`, read here rather than by the Core.
    private func nextFrame() throws -> [UInt8]? {
        guard let space = buffer.firstIndex(of: 0x20) else {
            if buffer.count > 8 { throw Failure(description: "a frame header that is not a length") }
            return nil
        }
        guard let length = Int(String(decoding: buffer[..<space], as: UTF8.self)), length >= 0 else {
            throw Failure(description: "a frame header that is not a length")
        }
        guard buffer.count >= space + 1 + length + 1 else { return nil }
        guard buffer[space + 1 + length] == 0x0A else { throw Failure(description: "a frame longer than its length") }
        let frame = Array(buffer[(space + 1)..<(space + 1 + length)])
        buffer.removeFirst(space + 2 + length)
        return frame
    }
}
