import Citadel
import Crypto
import Foundation
import LampBoardCore
import NIOCore
import NIOSSH

/// One ssh connection to one machine (§2.4 of the mobile plan).
///
/// It is opened with `SSHClient.connect(host:port:)`; the variant that takes a
/// channel crashes in Debug (S-C). The host key is checked against what was
/// pinned before a single byte of ours is sent, and the key decides which kind
/// of connection comes back: a read key gets a `ReadConnection`, which can only
/// open `v1`; an action key gets an `ActionConnection`, which can also run a
/// command. There is no PTY here yet (W8) and no SFTP (Citadel's `openSFTP`
/// has no deadline of its own, E12).
///
/// Citadel's streaming exec needs macOS 15; the Mac app does not use NodeLink,
/// and iOS 17 and Linux have it.
@available(macOS 15.0, *)
public enum NodeLink {

    /// A connection that only reads.
    public static func read(_ endpoint: NodeEndpoint, trust: HostKeyTrust, key: ReadKey,
                            deadlines: NodeDeadlines = .standard) async throws -> ReadConnection {
        ReadConnection(try await SSHLink.open(endpoint, trust: trust, key: key.key, deadlines: deadlines))
    }

    /// A connection that can act.
    public static func act(_ endpoint: NodeEndpoint, trust: HostKeyTrust, key: ActionKey,
                           deadlines: NodeDeadlines = .standard) async throws -> ActionConnection {
        ActionConnection(try await SSHLink.open(endpoint, trust: trust, key: key.key, deadlines: deadlines))
    }
}

/// What the read key can do: open `v1`.
@available(macOS 15.0, *)
public final class ReadConnection: @unchecked Sendable {
    let link: SSHLink

    init(_ link: SSHLink) { self.link = link }

    /// The host key the machine presented: the one to pin after `firstUse`.
    public var hostKey: NodeHostKey { link.hostKey }

    /// The `v1` channel. On a node the key's forced command serves it whatever
    /// the name; on the Mac the server answers this name only (S-R, S-C v2).
    public func openV1() async throws -> NodeByteChannel { try await link.exec("v1") }

    public func close() async { await link.close() }

    /// Probes only: an exec of anything with the read key, to prove the
    /// machine refuses it. The app never calls this.
    @_spi(Probe) public func openAnything(_ command: String) async throws -> NodeByteChannel {
        try await link.exec(command)
    }
}

/// What the action key can do: `v1`, and commands.
@available(macOS 15.0, *)
public final class ActionConnection: @unchecked Sendable {
    let link: SSHLink

    init(_ link: SSHLink) { self.link = link }

    public var hostKey: NodeHostKey { link.hostKey }

    public func openV1() async throws -> NodeByteChannel { try await link.exec("v1") }

    /// Runs `command` and returns what it printed and how it ended. Output past
    /// `limit` bytes is an error, not a truncation nobody sees.
    public func run(_ command: String, limit: Int = 1 << 20) async throws -> NodeCommandResult {
        try await link.run(command, limit: limit)
    }

    public func close() async { await link.close() }
}

/// How a command ended.
public struct NodeCommandResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int

    public init(output: String, exitCode: Int) {
        self.output = output
        self.exitCode = exitCode
    }
}

// MARK: - The connection under both

@available(macOS 15.0, *)
final class SSHLink: @unchecked Sendable {
    let client: SSHClient
    let hostKey: NodeHostKey
    let deadlines: NodeDeadlines

    private init(client: SSHClient, hostKey: NodeHostKey, deadlines: NodeDeadlines) {
        self.client = client
        self.hostKey = hostKey
        self.deadlines = deadlines
    }

    static func open(_ endpoint: NodeEndpoint, trust: HostKeyTrust, key: P256.Signing.PrivateKey,
                     deadlines: NodeDeadlines) async throws -> SSHLink {
        let judge = HostKeyJudge(trust: trust)
        do {
            let client = try await NodeDeadline.run(
                deadlines.connect, "connecting to \(endpoint)",
                late: { (late: SSHClient) in Task { try? await late.close() } }
            ) {
                try await SSHClient.connect(
                    host: endpoint.host, port: endpoint.port,
                    authenticationMethod: .p256(username: endpoint.user, privateKey: key),
                    hostKeyValidator: .custom(judge), reconnect: .never,
                    connectTimeout: .milliseconds(Int64(deadlines.connect * 1000))
                )
            }
            guard case .accepted(let accepted)? = judge.verdict else {
                try? await client.close()
                throw NodeLinkError.failed("connected to \(endpoint) without a host key verdict")
            }
            return SSHLink(client: client, hostKey: accepted, deadlines: deadlines)
        } catch {
            // A refused host key closes the connection under the handshake: say
            // what happened, not what it looked like from above.
            if case .refused(let presented, let expected)? = judge.verdict {
                throw NodeLinkError.hostKeyMismatch(presented: presented.openSSH, expected: expected.openSSH)
            }
            throw Self.describe(error, "connecting to \(endpoint)")
        }
    }

    func exec(_ command: String) async throws -> NodeByteChannel {
        try await ExecChannel.open(client, command: command, deadlines: deadlines)
    }

    func run(_ command: String, limit: Int) async throws -> NodeCommandResult {
        let client = self.client
        return try await NodeDeadline.run(deadlines.command, "running a command", expired: {
            Task { try? await client.close() }
        }) {
            var output: [UInt8] = []
            var exitCode = 0
            do {
                for try await chunk in try await client.executeCommandStream(command) {
                    if case .stdout(let buffer) = chunk { output += buffer.readableBytesView }
                    if output.count > limit { throw NodeLinkError.failed("a command printed more than \(limit) bytes") }
                }
            } catch let failed as SSHClient.CommandFailed {
                exitCode = failed.exitCode
            }
            return NodeCommandResult(output: String(decoding: output, as: UTF8.self), exitCode: exitCode)
        }
    }

    func close() async {
        let client = self.client
        _ = try? await NodeDeadline.run(deadlines.close, "closing the connection") {
            do { try await client.close() } catch where NodeLinkError.isNormalEnd(error) {}
        }
    }

    static func describe(_ error: Error, _ what: String) -> Error {
        if error is NodeLinkError { return error }
        // Citadel's errors are compared by name: some of its enums carry values
        // and are not Equatable.
        let text = String(describing: error)
        if text.contains("channelFailure") || text.contains("channelCreationFailed") {
            return NodeLinkError.refused("\(what): the machine refused the channel")
        }
        if text.contains("allAuthenticationOptionsFailed") {
            return NodeLinkError.refused("\(what): the machine refused the key")
        }
        return NodeLinkError.failed("\(what): \(text)")
    }
}

/// Citadel's host key hook, judging with `HostKeyVerdict` and remembering the
/// verdict so that a refusal can be told from a network failure.
final class HostKeyJudge: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trust: HostKeyTrust
    private let lock = NSLock()
    private var judged: HostKeyVerdict?

    init(trust: HostKeyTrust) { self.trust = trust }

    var verdict: HostKeyVerdict? {
        lock.lock()
        defer { lock.unlock() }
        return judged
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let verdict = HostKeyVerdict(trust: trust, presented: NodeHostKey(hostKey))
        lock.lock()
        judged = verdict
        lock.unlock()
        switch verdict {
        case .accepted: validationCompletePromise.succeed(())
        case .refused: validationCompletePromise.fail(NodeLinkError.refused("host key"))
        }
    }
}

// MARK: - An exec channel, held open

/// An exec channel kept open for as long as its user wants it, over Citadel's
/// `withExec`, which only lends the channel for the length of a closure: the
/// closure is kept running in a task of its own until the channel ends or is
/// closed, and the bytes it receives are passed on.
@available(macOS 15.0, *)
final class ExecChannel: NodeByteChannel, @unchecked Sendable {
    let inbound: AsyncStream<[UInt8]>
    private let feed: AsyncStream<[UInt8]>.Continuation
    private let deadlines: NodeDeadlines
    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var ended = false

    private init(deadlines: NodeDeadlines) {
        self.deadlines = deadlines
        (inbound, feed) = AsyncStream.makeStream(of: [UInt8].self)
    }

    static func open(_ client: SSHClient, command: String, deadlines: NodeDeadlines) async throws -> ExecChannel {
        let channel = ExecChannel(deadlines: deadlines)
        try await NodeDeadline.run(deadlines.open, "opening the channel", expired: {
            channel.task?.cancel()
        }) {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
                let gate = NodeDeadline.Gate()
                channel.task = Task {
                    do {
                        try await client.withExec(command) { output, input in
                            channel.lend(input)
                            if gate.claim() { ready.resume() }
                            do {
                                for try await chunk in output {
                                    if case .stdout(let buffer) = chunk { channel.feed.yield(Array(buffer.readableBytesView)) }
                                }
                            } catch {
                                // The command ended badly or the channel was
                                // refused: either way, this channel is over.
                            }
                        }
                    } catch {
                        if gate.claim() {
                            ready.resume(throwing: SSHLink.describe(error, "opening the channel"))
                        }
                        // After the channel was open: the machine closed it
                        // first (`alreadyClosed`), or it went with the connection.
                    }
                    channel.end()
                }
            }
        }
        return channel
    }

    func write(_ bytes: [UInt8]) async throws {
        guard let writer = current() else { throw NodeLinkError.closed }
        let seconds = deadlines.write
        try await NodeWrites.inPieces(bytes) { piece in
            try await NodeDeadline.run(seconds, "writing to the channel") {
                do {
                    try await writer.write(ByteBuffer(bytes: piece))
                } catch {
                    if error is ChannelError { throw NodeLinkError.closed }
                    throw error
                }
            }
        }
    }

    func close() async {
        task?.cancel()
        end()
    }

    private func lend(_ writer: TTYStdinWriter) {
        lock.lock()
        self.writer = writer
        lock.unlock()
    }

    private func current() -> TTYStdinWriter? {
        lock.lock()
        defer { lock.unlock() }
        return ended ? nil : writer
    }

    private func end() {
        lock.lock()
        let first = !ended
        ended = true
        writer = nil
        lock.unlock()
        if first { feed.finish() }
    }
}
