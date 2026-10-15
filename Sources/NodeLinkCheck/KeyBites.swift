import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import TestKit

/// What the keys may and may not do on a real node, and what NodeLink does
/// when the machine is not the one pinned, says nothing, or ends a channel.
@available(macOS 15.0, *)
enum KeyBites {

    static func suite(_ node: CheckedNode) -> TestSuite {
        TestSuite("NodeLink over ssh: \(node.endpoint.host)", [

            TestCase("The pinned host key gets in, and is the key the machine presents") { t in
                let presented = try? Blocking.run(30) { () async throws -> NodeHostKey in
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                    await connection.close()
                    return connection.hostKey
                }
                t.expectEqual(presented, node.hostKey, "the pinned key")
            },

            TestCase("First use, asked for by name, hands back the key to pin") { t in
                let presented = try? Blocking.run(30) { () async throws -> NodeHostKey in
                    let connection = try await NodeLink.read(node.endpoint, trust: .firstUse, key: node.readKey)
                    await connection.close()
                    return connection.hostKey
                }
                t.expectEqual(presented?.fingerprint, node.hostKey.fingerprint, "the machine's key")
            },

            TestCase("A changed host key is refused, and nothing is opened") { t in
                let outcome = Result { try Blocking.run(30) { () async throws -> String in
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.wrongHostKey), key: node.readKey)
                    _ = try await connection.openV1()
                    return "opened"
                } }
                switch outcome {
                case .success: t.expect(false, "a connection was made to a machine with another key")
                case .failure(let error):
                    t.expectEqual(error as? NodeLinkError,
                                  .hostKeyMismatch(presented: node.hostKey.openSSH, expected: node.wrongHostKey.openSSH),
                                  "said which key it saw")
                }
            },

            TestCase("A key the machine does not know is refused") { t in
                let outcome = Result { try Blocking.run(30) {
                    _ = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: ReadKey.generate())
                } }
                if case .failure(let error as NodeLinkError) = outcome, case .refused = error {
                    t.expect(true, "refused")
                } else {
                    t.expect(false, "expected a refusal, got \(outcome)")
                }
            },

            TestCase("The read key asking for anything else gets v1, and the command never runs") { t in
                let mark = "/tmp/lbcheck-breach-\(UInt32.random(in: 1...UInt32.max))"
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
                let check = try? Blocking.run(30) { () async throws -> (String, String) in
                    let connection = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    let exists = try await connection.run("test -e \(mark) && echo present || echo absent")
                    let logged = try await connection.run("grep -c -F 'asked=\(asked)' \(node.log) || true")
                    await connection.close()
                    return (exists.output, logged.output)
                }
                t.expectEqual(check?.0, "absent\n", "nothing was created on the node")
                t.expect((Int(check?.1.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0) >= 1,
                         "the attempt is in the node's log as a datum")
            },

            TestCase("The action key runs a command and says how it ended") { t in
                let results = try? Blocking.run(30) { () async throws -> [NodeCommandResult] in
                    let connection = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    let ok = try await connection.run("echo example")
                    let failed = try await connection.run("exit 3")
                    await connection.close()
                    return [ok, failed]
                }
                t.expectEqual(results?.first, NodeCommandResult(output: "example\n", exitCode: 0), "printed and ended well")
                t.expectEqual(results?.last?.exitCode, 3, "the exit code of a failure")
            },

            TestCase("A machine that never answers costs the deadline, not for ever") { t in
                let silent = NodeEndpoint(host: node.endpoint.host, port: node.silentPort, user: node.endpoint.user)
                let start = Date()
                let outcome = Result { try Blocking.run(30) {
                    _ = try await NodeLink.read(silent, trust: .pinned(node.hostKey), key: node.readKey,
                                                deadlines: NodeDeadlines(connect: 2))
                } }
                let took = Date().timeIntervalSince(start)
                if case .failure(let error as NodeLinkError) = outcome, case .timedOut = error {
                    t.expect(took < 5, "within the deadline: \(took) s")
                } else {
                    t.expect(false, "expected a timeout, got \(outcome)")
                }
            },

            TestCase("A v1 channel the machine ends is a normal end, and its writes are refused after") { t in
                let outcome = try? Blocking.run(30) { () async throws -> (Bool, Bool) in
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                    let channel = try await connection.openV1()
                    // Protocol 0 is below minClient: the node answers and ends the stream.
                    let hello = try V1Codec.encode(V1ClientMessage(id: 1, .hello(protocol: 0, client: "ancient")))
                    try await channel.write(V1Frame.encode(hello))
                    var ended = false
                    for await _ in channel.inbound {}
                    ended = true
                    var refused = false
                    do { try await channel.write([0x0A]) } catch { refused = (error as? NodeLinkError) == .closed }
                    await connection.close()
                    return (ended, refused)
                }
                t.expectEqual(outcome?.0, true, "the inbound stream finished")
                t.expectEqual(outcome?.1, true, "a write after the end is refused as closed")
            },

            TestCase("The link carries the v1 client over ssh: rows, then each change") { t in
                let link = V1Link(name: "check", pingInterval: 1, backoff: [0.2]) {
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                    return try await ClosingChannel.wrap(connection.openV1()) { await connection.close() }
                }
                _ = try? Blocking.run { await link.start() }
                t.expect(Blocking.eventually(15) { await link.rows.count >= 3 }, "the rows arrived")
                let before = (try? Blocking.run { await link.lastSeq }) ?? nil
                let provoked = try? Blocking.run(30) { () async throws -> Int in
                    let connection = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    let result = try await connection.run("\(node.reference) provoke --socket \(node.socket) 2")
                    await connection.close()
                    return result.exitCode
                }
                t.expectEqual(provoked, 0, "provoked")
                t.expect(Blocking.eventually(15) { await link.lastSeq == (before ?? -10) + 2 }, "two events followed")
                _ = try? Blocking.run { await link.stop() }
            },
        ])
    }
}

/// A channel that also closes its connection when it is closed: the link opens
/// one connection per channel.
@available(macOS 15.0, *)
final class ClosingChannel: NodeByteChannel, @unchecked Sendable {
    private let inner: NodeByteChannel
    private let closing: () async -> Void
    var inbound: AsyncStream<[UInt8]> { inner.inbound }

    private init(_ inner: NodeByteChannel, closing: @escaping () async -> Void) {
        self.inner = inner
        self.closing = closing
    }

    static func wrap(_ inner: NodeByteChannel, closing: @escaping () async -> Void) -> NodeByteChannel {
        ClosingChannel(inner, closing: closing)
    }

    func write(_ bytes: [UInt8]) async throws { try await inner.write(bytes) }

    func close() async {
        await inner.close()
        await closing()
    }
}
