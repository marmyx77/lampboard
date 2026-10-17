import Crypto
import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import ProtocolConformance
import TestKit

/// The node with `lampd` installed as on the Linux machine (W3): OpenSSH on a
/// port of its own, the phone's lines written by `lampd devices add`, Claude
/// Code's files played by the fixture, and the service running as the account.
struct LampDNode {
    let endpoint: NodeEndpoint
    let hostKey: NodeHostKey
    /// The paired phone's two keys.
    let readKey: ReadKey
    let actionKey: ActionKey
    /// A phone paired with `from=` set to a network the check is not on.
    let farReadKey: ReadKey
    /// A phone paired and then revoked.
    let lostReadKey: ReadKey
    let lostActionKey: ActionKey
    /// The house's own line, not LampBoard's: it must still open after every
    /// add and revoke.
    let houseKey: ActionKey
    /// `authorized_keys` as the house had it before `lampd` wrote anything.
    let houseLines: String
    let lampd: String
    let fixture: String
    let log: String
    let name: String
}

/// `lampd` reached through NodeLink, as the phone reaches it: the conformance
/// battery with the read key, the source changed with the action key by the
/// fixture and a look asked of the service.
@available(macOS 15.0, *)
final class LampDTarget: V1ConformanceTarget {
    let name = "lampd over ssh"
    let pingInterval: TimeInterval = 0.5
    private let node: LampDNode
    private var actor: ActionConnection?

    init(_ node: LampDNode) { self.node = node }

    func connect(role: V1Role) throws -> V1ByteStream {
        let node = self.node
        return try Blocking.run(30) { () async throws -> SSHByteStream in
            let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
            return SSHByteStream(try await connection.openV1()) { await connection.close() }
        }
    }

    func provoke(_ count: Int) throws {
        for _ in 0..<count {
            let result = try run("python3 \(node.fixture) flip > /dev/null && \(node.lampd) look")
            guard result.exitCode == 0 else { throw NodeLinkError.failed("provoke exited \(result.exitCode): \(result.output)") }
        }
    }

    func run(_ command: String) throws -> NodeCommandResult {
        let node = self.node
        let existing = actor
        let connection = try Blocking.run(30) { () async throws -> ActionConnection in
            if let existing { return existing }
            return try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
        }
        actor = connection
        return try Blocking.run(60) { try await connection.run(command) }
    }

    func finish() {
        guard let actor else { return }
        _ = try? Blocking.run(10) { await actor.close() }
    }
}

@available(macOS 15.0, *)
enum LampDChecks {

    static func suites(_ node: LampDNode, _ target: LampDTarget) -> [TestSuite] {
        [V1Conformance.suite(against: target), keys(node, target), rule(node, target), stopped(node, target)]
    }

    // MARK: - The keys `lampd devices add` wrote

    static func keys(_ node: LampDNode, _ target: LampDTarget) -> TestSuite {
        TestSuite("lampd over ssh: the phone's lines", [

            TestCase("The read key cannot open a terminal: its line has no pty") { t in
                let outcome = Result { try Blocking.run(30) { () async throws -> String in
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                    defer { Task { await connection.close() } }
                    let terminal = try await connection.openTerminalAnyway(command: "id", size: TerminalSize(columns: 80, rows: 24)!)
                    await terminal.close()
                    return "opened"
                } }
                if case .failure(let error as NodeLinkError) = outcome, case .refused = error {
                    t.expect(true, "refused")
                } else {
                    t.expect(false, "the read key's terminal was not refused: \(outcome)")
                }
            },

            TestCase("The read key asking for anything else gets v1, and the command never runs") { t in
                let mark = "/tmp/lampd-breach-\(UInt32.random(in: 1...UInt32.max))"
                let asked = "touch \(mark); echo BREACH"
                let answer = try? Blocking.run(30) { () async throws -> [UInt8] in
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                    defer { Task { await connection.close() } }
                    let channel = try await connection.openAnything(asked)
                    let hello = try V1Codec.encode(V1ClientMessage(id: 1, .hello(protocol: V1Protocol.version, client: "check")))
                    try await channel.write(V1Frame.encode(hello))
                    var bytes: [UInt8] = []
                    for await chunk in channel.inbound {
                        bytes += chunk
                        if bytes.contains(0x0A) { break }
                    }
                    await channel.close()
                    return bytes
                }
                let text = String(decoding: answer ?? [], as: UTF8.self)
                t.expect(text.contains("\"type\":\"hello\""), "the forced command answered v1: \(text.prefix(80))")
                t.expect(!text.contains("BREACH"), "and the command's own output never came")
                let exists = try? target.run("test -e \(mark) && echo present || echo absent").output
                let logged = try? target.run("grep -c -F 'asked=\(asked)' \(node.log) || true").output
                t.expectEqual(exists, "absent\n", "nothing was created on the node")
                t.expect((Int(logged?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0) >= 1,
                         "the attempt is in lampd's log as a datum")
            },

            TestCase("A phone whose from= is another network is refused") { t in
                let outcome = Result { try Blocking.run(30) {
                    _ = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.farReadKey)
                } }
                if case .failure(let error as NodeLinkError) = outcome, case .refused = error {
                    t.expect(true, "refused")
                } else {
                    t.expect(false, "a key from the wrong network got in: \(outcome)")
                }
            },

            TestCase("A revoked phone is refused with both its keys") { t in
                let read = Result { try Blocking.run(30) {
                    _ = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.lostReadKey)
                } }
                let action = Result { try Blocking.run(30) {
                    _ = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.lostActionKey)
                } }
                for (name, outcome) in [("read", read), ("action", action)] {
                    if case .failure(let error as NodeLinkError) = outcome, case .refused = error {
                        t.expect(true, "\(name) refused")
                    } else {
                        t.expect(false, "a revoked key got in (\(name)): \(outcome)")
                    }
                }
            },

            TestCase("The house's own lines are as they were, and its key still opens") { t in
                let text = try? Blocking.run(30) { () async throws -> String in
                    let connection = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.houseKey)
                    defer { Task { await connection.close() } }
                    return try await connection.run("cat ~/.ssh/authorized_keys").output
                }
                t.expect(text != nil, "the house key opened")
                let others = (text ?? "").components(separatedBy: "\n").filter { !$0.contains("lampboard-device:") }
                let before = node.houseLines.components(separatedBy: "\n")
                t.expectEqual(others.filter { !$0.isEmpty }, before.filter { !$0.isEmpty },
                              "the lines that are not LampBoard's, byte for byte")
                let marked = (text ?? "").components(separatedBy: "\n").filter { $0.contains("lampboard-device:") }
                t.expectEqual(marked.count, 4, "the two phones still paired, two lines each: \(marked.count)")
                t.expect(!(text ?? "").contains("lampboard-device:lost-phone"), "the revoked phone has no line")
            },

            TestCase("The action key opens a raw terminal that carries 10 MiB byte for byte") { t in
                let outcome = try? Blocking.run(120) { () async throws -> (String, String, Int) in
                    let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    defer { Task { await action.close() } }
                    let made = try await action.run(
                        "head -c 10485760 /dev/urandom > /tmp/lampd-raw.bin && sha256sum /tmp/lampd-raw.bin | cut -d' ' -f1")
                    let terminal = try await action.openTerminal(command: "stty raw -echo; cat /tmp/lampd-raw.bin",
                                                                 size: TerminalSize(columns: 80, rows: 24)!)
                    var bytes: [UInt8] = []
                    for await chunk in terminal.inbound { bytes += chunk }
                    _ = try? await action.run("rm -f /tmp/lampd-raw.bin")
                    let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                    return (made.output.trimmingCharacters(in: .whitespacesAndNewlines), digest, bytes.count)
                }
                t.expectEqual(outcome?.2, 10_485_760, "every byte arrived")
                t.expect(outcome != nil && outcome?.0 == outcome?.1, "the action key's terminal carried the bytes unchanged")
            },
        ])
    }

    // MARK: - One rule for the files

    /// The lamp of a row: what the rule of the files decides. The person's
    /// choices and a job's words are `lampd`'s additions and not compared.
    static func lamp(_ row: V1Row) -> [String: String] {
        let s = row.session
        return [
            "status": s.status, "updatedAt": "\(s.updatedAt.timeIntervalSince1970)",
            "statusSince": "\(s.statusSince.timeIntervalSince1970)", "workspace": s.workspace, "path": s.path,
            "origin": s.origin, "entrypoint": s.entrypoint ?? "-", "title": s.title ?? "-",
            "contextTokens": s.contextTokens.map(String.init) ?? "-", "contextPercent": s.contextPercent.map(String.init) ?? "-",
            "contextModel": s.contextModel ?? "-", "contextConfidence": s.contextConfidence ?? "-",
            "harness": s.harness, "terminal": row.extras.terminal ?? "-", "basis": row.extras.stateBasis?.rawValue ?? "-",
            "host": s.host ?? "-",
        ]
    }

    static func rule(_ node: LampDNode, _ target: LampDTarget) -> TestSuite {
        TestSuite("lampd over ssh: one rule for the files", (0..<3).map { frame in
            TestCase("Frame \(frame): lampd and the phone's look give every session the same lamp") { t in
                let set = try? target.run("python3 \(node.fixture) frame \(frame) && \(node.lampd) look")
                t.expectEqual(set?.exitCode, 0, "the frame was played: \(set?.output ?? "")")
                let mine = (try? state(node))?.rows
                let probeSource = V1ProbeSource(identity: V1SourceIdentity(kind: .node, name: node.name), startedAt: Date(),
                                                journal: "check")
                let looked = try? Blocking.run(60) { () async throws -> Bool in
                    let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    defer { Task { await action.close() } }
                    let probe = ProbeLink(source: probeSource, interval: 3600) { command in try await action.run(command) }
                    return await probe.look()
                }
                t.expectEqual(looked, true, "the phone's look answered")
                let theirs = probeSource.snapshot(at: Date()).rows ?? []
                guard let mine else { t.expect(false, "lampd sent no rows"); return }
                t.expectEqual(Set(mine.map(\.id)), Set(theirs.map(\.id)), "the same sessions have rows")
                let byId = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
                for row in theirs {
                    guard let other = byId[row.id] else { continue }
                    t.expectEqual(lamp(other), lamp(row), "the same lamp for \(row.id.prefix(13)) (\(row.session.status))")
                }
                if frame == 0 {
                    t.expectEqual(mine.count, 9, "nine sessions earn a row; the dead, reused, silent and SDK ones none: \(mine.count)")
                    let statuses = Set(mine.map(\.session.status))
                    t.expectEqual(statuses, ["working", "waiting", "awaiting", "idle"], "every lamp the files can light")
                    t.expect(mine.contains { $0.session.jobId == "job-example-1" }, "the background session's job is on its row")
                }
                if frame == 2 { t.expectEqual(mine.count, 0, "an empty column, not an unknown one") }
            }
        })
    }

    // MARK: - The service stopped

    static func stopped(_ node: LampDNode, _ target: LampDTarget) -> TestSuite {
        TestSuite("lampd over ssh: the service stopped does not turn the lights off", [

            TestCase("With the service stopped the read key still gets the lights, read from the files") { t in
                _ = try? target.run("python3 \(node.fixture) frame 0 && \(node.lampd) look")
                let live = try? hello(node)
                t.expectEqual(live?.mode, .live, "first the service answers")
                let before = (try? state(node))?.rows ?? []
                let stop = try? target.run("kill $(cat /tmp/lampd.pid); for i in $(seq 50); do kill -0 $(cat /tmp/lampd.pid) 2>/dev/null || break; sleep 0.1; done; \(node.lampd) status > /dev/null; echo $?")
                t.expectEqual(stop?.output.trimmingCharacters(in: .whitespacesAndNewlines), "1", "the service is down")
                let files = try? hello(node)
                t.expectEqual(files?.mode, .files, "hello says the files are read")
                t.expectEqual(files?.role, .read, "with the read key alone")
                let after = (try? state(node))?.rows ?? []
                t.expectEqual(after.map(lamp), before.map(lamp), "the same lights")
                let restart = try? target.run("setsid nohup \(node.lampd) serve >> \(node.log) 2>&1 < /dev/null & echo $! > /tmp/lampd.pid; for i in $(seq 50); do \(node.lampd) status > /dev/null 2>&1 && break; sleep 0.1; done; \(node.lampd) status > /dev/null; echo $?")
                t.expectEqual(restart?.output.trimmingCharacters(in: .whitespacesAndNewlines), "0", "the service is back")
                t.expectEqual((try? hello(node))?.mode, .live, "and serves again")
            },
        ])
    }

    // MARK: - Helpers

    /// `hello`, then `state`, on a new read connection.
    static func exchange(_ node: LampDNode) throws -> (V1Hello?, V1State?) {
        try Blocking.run(30) { () async throws -> (V1Hello?, V1State?) in
            let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
            defer { Task { await connection.close() } }
            let channel = try await connection.openV1()
            for message in [V1ClientMessage(id: 1, .hello(protocol: V1Protocol.version, client: "check")),
                            V1ClientMessage(id: 2, .state)] {
                try await channel.write(V1Frame.encode(try V1Codec.encode(message)))
            }
            var reader = V1FrameReader()
            var hello: V1Hello?
            var state: V1State?
            for await chunk in channel.inbound {
                reader.push(chunk)
                while let frame = try reader.next() {
                    switch try V1Codec.decodeReply(frame).reply {
                    case .hello(let value): hello = value
                    case .state(let value): state = value
                    default: break
                    }
                }
                if state != nil { break }
            }
            await channel.close()
            return (hello, state)
        }
    }

    static func hello(_ node: LampDNode) throws -> V1Hello? { try exchange(node).0 }
    static func state(_ node: LampDNode) throws -> V1State? { try exchange(node).1 }
}
