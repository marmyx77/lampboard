import Crypto
import Foundation
import LampBoardCore
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// A terminal's size in characters.
public struct TerminalSize: Equatable, Sendable, CustomStringConvertible {
    public let columns: Int
    public let rows: Int

    /// `nil` outside 1…1000: no screen has a zero side, and a number a client
    /// made up should not reach the other machine's `TIOCSWINSZ`.
    public init?(columns: Int, rows: Int) {
        guard (1...1000).contains(columns), (1...1000).contains(rows) else { return nil }
        self.columns = columns
        self.rows = rows
    }

    public var description: String { "\(columns)x\(rows)" }
}

/// A terminal on another machine (D176): `pty-req`, then `exec` of a command —
/// what `ssh -t host tmux -u attach -t <session>` does — on a channel of its own
/// connection, opened on a bare `NIOSSHHandler`, because Citadel's `withPTY`
/// sends `shell` and types the command into it (S-C), and its `connect(on:)`
/// crashes in Debug (S-C mobile). About forty lines of NIO, as W0 measured.
///
/// - Bytes arrive on `inbound` in pieces of at most 32 KiB, in order, and leave
///   through `write`, cut the same way: swift-nio-ssh does not split a write
///   larger than the channel's window (S-R).
/// - `resize` sends `window-change`; nothing else is needed (S-S).
/// - The machine ending the channel first is the normal end (`alreadyClosed`,
///   measured at the end of every attach): `inbound` finishes, `exitStatus`
///   says how the command ended, and the connection is closed with it.
/// - Every step has its deadline: the connection, the channel and its two
///   requests, each write, the close.
///
/// Byte for byte on the raw channel; through tmux the screen is tmux's, which
/// skips what it does not repaint (E7): the history comes from tmux, not from
/// these bytes.
public final class NodeTerminal: NodeByteChannel, @unchecked Sendable {
    public let inbound: AsyncStream<[UInt8]>
    public let size: TerminalSize

    private let feed: AsyncStream<[UInt8]>.Continuation
    private let deadlines: NodeDeadlines
    private let lock = NSLock()
    private var parent: Channel?
    private var child: Channel?
    private var ended = false
    private var status: Int?

    private init(size: TerminalSize, deadlines: NodeDeadlines) {
        self.size = size
        self.deadlines = deadlines
        (inbound, feed) = AsyncStream.makeStream(of: [UInt8].self)
    }

    /// A terminal nobody closed does not keep its connection.
    deinit {
        parent?.close(promise: nil)
        feed.finish()
    }

    /// How the command ended, once the machine said; `nil` before, or when it
    /// never did (a closed connection carries no status).
    public var exitStatus: Int? { lock.lock(); defer { lock.unlock() }; return status }

    /// `true` once the channel is over, whoever ended it.
    public var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    // MARK: - Opening

    static func open(_ endpoint: NodeEndpoint, hostKey: NodeHostKey, key: P256.Signing.PrivateKey, command: String,
                     size: TerminalSize, term: String, deadlines: NodeDeadlines) async throws -> NodeTerminal {
        let terminal = NodeTerminal(size: size, deadlines: deadlines)
        let judge = HostKeyJudge(trust: .pinned(hostKey))
        let parent: Channel
        do {
            parent = try await NodeDeadline.run(
                deadlines.connect, "connecting to \(endpoint)",
                late: { (late: Channel) in late.close(promise: nil) }
            ) {
                try await TerminalConnection.connect(endpoint, judge: judge, key: key, timeout: deadlines.connect)
            }
        } catch {
            if case .refused(let presented, let expected)? = judge.verdict {
                throw NodeLinkError.hostKeyMismatch(presented: presented.openSSH, expected: expected.openSSH)
            }
            throw NodeErrorWords.describe(error, "connecting to \(endpoint)")
        }
        terminal.adopt(parent: parent)
        do {
            try await NodeDeadline.run(deadlines.open, "opening the terminal", expired: { parent.close(promise: nil) }) {
                try await terminal.start(on: parent, command: command, term: term)
            }
        } catch {
            parent.close(promise: nil)
            terminal.end()
            throw NodeErrorWords.describe(error, "opening the terminal")
        }
        return terminal
    }

    private func start(on parent: Channel, command: String, term: String) async throws {
        let handler = TerminalHandler(
            received: { [weak self] buffer in self?.received(buffer) },
            exited: { [weak self] code in self?.exited(code) },
            ended: { [weak self] in self?.end() }
        )
        let child: Channel = try await parent.eventLoop.flatSubmit {
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.pipeline.addHandler(handler)
                }
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }.get()
        lock.withLock { self.child = child }
        try await handler.ask(SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term,
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        ), on: child, refusal: "the machine refused the terminal")
        try await handler.ask(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                              on: child, refusal: "the machine refused the command")
    }

    private func adopt(parent: Channel) {
        lock.withLock { self.parent = parent }
        // The connection going (network, the machine) ends the terminal too.
        parent.closeFuture.whenComplete { [weak self] _ in self?.end() }
    }

    // MARK: - Using it

    public func write(_ bytes: [UInt8]) async throws {
        guard let child = current() else { throw NodeLinkError.closed }
        let seconds = deadlines.write
        try await NodeWrites.inPieces(bytes) { piece in
            try await NodeDeadline.run(seconds, "writing to the terminal") {
                do {
                    try await child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: piece))))
                } catch {
                    if error is ChannelError { throw NodeLinkError.closed }
                    throw error
                }
            }
        }
    }

    /// Tells the machine the terminal's new size (`window-change`).
    public func resize(_ size: TerminalSize) async throws {
        guard let child = current() else { throw NodeLinkError.closed }
        try await NodeDeadline.run(deadlines.write, "resizing the terminal") {
            do {
                try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0
                ))
            } catch {
                if error is ChannelError { throw NodeLinkError.closed }
                throw error
            }
        }
    }

    /// Ends the terminal and its connection. Twice, or after the machine did,
    /// is not an error.
    public func close() async {
        let (child, parent) = lock.withLock { (self.child, self.parent) }
        _ = try? await NodeDeadline.run(deadlines.close, "closing the terminal") {
            if let child {
                do { try await child.close() } catch where NodeLinkError.isNormalEnd(error) {} catch {}
            }
            if let parent {
                do { try await parent.close() } catch where NodeLinkError.isNormalEnd(error) {} catch {}
            }
        }
        end()
    }

    // MARK: - Inside

    private func current() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return ended ? nil : child
    }

    private func received(_ buffer: ByteBuffer) {
        for piece in V1Frame.pieces(Array(buffer.readableBytesView)) { feed.yield(piece) }
    }

    private func exited(_ code: Int) {
        lock.withLock { status = code }
    }

    private func end() {
        let (first, parent) = lock.withLock { () -> (Bool, Channel?) in
            let first = !ended
            ended = true
            return (first, self.parent)
        }
        guard first else { return }
        feed.finish()
        parent?.close(promise: nil)
    }
}

// MARK: - The connection and the channel's handler

/// One ssh connection on a bare `NIOSSHHandler`: the host key judged by the
/// same `HostKeyJudge` as every other connection, the action key offered once.
enum TerminalConnection {

    static func connect(_ endpoint: NodeEndpoint, judge: HostKeyJudge, key: P256.Signing.PrivateKey,
                        timeout: TimeInterval) async throws -> Channel {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let config = SSHClientConfiguration(
            userAuthDelegate: OneKeyOffer(user: endpoint.user, key: NIOSSHPrivateKey(p256Key: key)),
            serverAuthDelegate: judge
        )
        let channel = try await ClientBootstrap(group: loop)
            .connectTimeout(.milliseconds(Int64(max(0.1, timeout) * 1000)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        AuthenticationWaiter(authenticated)
                    )
                }
            }
            .connect(host: endpoint.host, port: endpoint.port).get()
        do {
            try await authenticated.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return channel
    }
}

/// Offers one private key, once; after a refusal there is nothing else to try.
final class OneKeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let key: NIOSSHPrivateKey
    private var offered = false

    init(user: String, key: NIOSSHPrivateKey) {
        self.user = user
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))
        ))
    }
}

/// Answers once: authenticated, or why not.
final class AuthenticationWaiter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let promise: EventLoopPromise<Void>
    private var answered = false

    init(_ promise: EventLoopPromise<Void>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { answer(nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        answer(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        answer(NodeLinkError.refused("the machine closed the connection before letting the key in"))
        context.fireChannelInactive()
    }

    private func answer(_ error: Error?) {
        guard !answered else { return }
        answered = true
        if let error { promise.fail(error) } else { promise.succeed(()) }
    }
}

/// The terminal channel's handler, on the event loop: bytes in, the replies to
/// `pty-req` and `exec` in order, the exit status, and the end.
final class TerminalHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let received: (ByteBuffer) -> Void
    private let exited: (Int) -> Void
    private let ended: () -> Void
    /// Promises for the requests sent with `wantReply`, answered in order (RFC 4254 §5.4).
    private var replies: [(promise: EventLoopPromise<Void>, refusal: String)] = []
    private var inactive = false

    init(received: @escaping (ByteBuffer) -> Void, exited: @escaping (Int) -> Void, ended: @escaping () -> Void) {
        self.received = received
        self.exited = exited
        self.ended = ended
    }

    /// Sends `request` and waits for the machine's yes or no.
    func ask(_ request: Any, on channel: Channel, refusal: String) async throws {
        try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            guard !self.inactive else { return channel.eventLoop.makeFailedFuture(NodeLinkError.closed) }
            let promise = channel.eventLoop.makePromise(of: Void.self)
            self.replies.append((promise, refusal))
            return channel.triggerUserOutboundEvent(request).flatMap { promise.futureResult }
        }.get()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenComplete { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        received(buffer)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !replies.isEmpty { replies.removeFirst().promise.succeed(()) }
        case is ChannelFailureEvent:
            if !replies.isEmpty {
                let pending = replies.removeFirst()
                pending.promise.fail(NodeLinkError.refused(pending.refusal))
            }
        case let status as SSHChannelRequestEvent.ExitStatus:
            exited(status.exitStatus)
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            // The command's output is over: the terminal is.
            context.close(promise: nil)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inactive = true
        let pending = replies
        replies = []
        for reply in pending { reply.promise.fail(NodeLinkError.closed) }
        ended()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
