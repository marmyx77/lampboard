#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import LampBoardCore
import NIOCore
@preconcurrency import NIOSSH

/// One session channel of the Mac's server: one request, then its bytes.
///
/// Every request is read whole (`MacRequest.parse`), judged (`MacPolicy`), and
/// only then carried out. A refusal is a channel failure and, for an exec, the
/// channel closed: nothing of what was asked ran.
final class MacChannel: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private enum Mode {
        case idle
        case v1
        case pairing([UInt8])
        case terminal(MacPty)
        case shared(MacSharedTerminal, job: String)
        case done
    }

    private unowned let server: MacSSHServer
    private let connection: MacConnection
    private var mode: Mode = .idle
    private var terminalSize: (term: String, columns: Int, rows: Int)?
    private var service: V1Service?
    private var poller: RepeatedTask?
    private var observer: UUID?
    private var context: ChannelHandlerContext?

    init(server: MacSSHServer, connection: MacConnection) {
        self.server = server
        self.connection = connection
    }

    private var services: MacSSHServer.Services { server.services }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenComplete { _ in }
    }

    // MARK: - Requests

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            guard case .idle = mode, MacPolicy.mayAskForTerminal(connection.peer, terminalsOn: services.terminalsOn()) else {
                return refuse(context, request.wantReply, "a terminal", close: false)
            }
            terminalSize = (request.term, request.terminalCharacterWidth, request.terminalRowHeight)
            reply(context, request.wantReply, true)
        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            terminalSize?.columns = request.terminalCharacterWidth
            terminalSize?.rows = request.terminalRowHeight
            if case .terminal(let pty) = mode { pty.resize(columns: request.terminalCharacterWidth, rows: request.terminalRowHeight) }
        case let request as SSHChannelRequestEvent.ExecRequest:
            handle(context, line: request.command, wantReply: request.wantReply)
        case let request as SSHChannelRequestEvent.SubsystemRequest:
            // The subsystem `v1` is the same as the exec line; any other is not one.
            handle(context, line: request.subsystem == "v1" ? "v1" : "subsystem \(request.subsystem)", wantReply: request.wantReply)
        case let request as SSHChannelRequestEvent.ShellRequest:
            refuse(context, request.wantReply, "a shell", close: true)
        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            reply(context, request.wantReply, false)
        case let event as ChannelEvent where event == .inputClosed:
            if case .pairing(let bytes) = mode { pair(context, bytes) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func handle(_ context: ChannelHandlerContext, line: String, wantReply: Bool) {
        guard case .idle = mode, let peer = connection.peer else {
            return refuse(context, wantReply, "a second request on one channel", close: true)
        }
        let request = MacRequest.parse(line)
        let verdict = MacPolicy.decide(request, from: peer, terminalsOn: services.terminalsOn(), hasTerminal: terminalSize != nil)
        guard case .allow = verdict, let request else {
            if case .refuse(let why) = verdict {
                services.log("mac server: connection \(connection.number) refused \(Self.label(request, line)): \(why)")
                // Said on the channel before it closes, so the phone can say it too.
                _ = write(context, Array((why + "\n").utf8), stream: .stdErr)
            }
            return refuse(context, wantReply, Self.label(request, line), close: true)
        }
        switch request {
        case .v1:
            reply(context, wantReply, true)
            startV1(context, peer: peer)
        case .pair:
            reply(context, wantReply, true)
            mode = .pairing([])
        case .attach(let target):
            attach(context, target, wantReply: wantReply)
        case .action(let action):
            reply(context, wantReply, true)
            run(context, action)
        case .background:
            reply(context, wantReply, true)
            let clients = server.terminals(of: peer.v1Peer?.device ?? "")
            let runner = services.runner
            let services = self.services
            oneShot(context) {
                let done = runner.background(clients: clients, log: services.log)
                return (Array((#"{"detached":"# + "\(done.count)}\n").utf8), 0)
            }
        case .palette:
            reply(context, wantReply, true)
            let runner = services.runner
            oneShot(context) { (runner.palette(), 0) }
        }
    }

    /// What a refusal names in the log: the request's kind, never its arguments.
    private static func label(_ request: MacRequest?, _ line: String) -> String {
        guard let request else { return "an unnamed request (\(line.prefix(24))…)" }
        switch request {
        case .v1: return "v1"
        case .pair: return "pair"
        case .attach: return "attach"
        case .action(let action): return "action \(action.name)"
        case .background: return "background"
        case .palette: return "palette"
        }
    }

    // MARK: - v1

    private func startV1(_ context: ChannelHandlerContext, peer: MacPeer) {
        guard let v1Peer = peer.v1Peer else { return finish(context, status: 1) }
        mode = .v1
        service = V1Service(source: services.source, peer: v1Peer)
        let loop = context.eventLoop
        observer = services.source.observe { [weak self] in loop.execute { self?.pollV1() } }
        let interval = Int64(server.configuration.pollInterval * 1000)
        poller = loop.scheduleRepeatedTask(initialDelay: .milliseconds(interval), delay: .milliseconds(interval)) { [weak self] _ in
            self?.pollV1()
        }
    }

    private func pollV1() {
        guard let context, case .v1 = mode, var current = service else { return }
        let out = current.poll(at: services.now())
        service = current
        send(context, out)
        if current.isClosed { finish(context, status: 0) }
    }

    private func receiveV1(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        guard var current = service else { return }
        let out = current.receive(bytes, at: services.now())
        service = current
        send(context, out)
        if current.isClosed { finish(context, status: 0) }
    }

    private func stopV1() {
        poller?.cancel()
        poller = nil
        if let observer { services.source.stopObserving(observer) }
        observer = nil
    }

    // MARK: - Pairing

    private func pair(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        mode = .done
        let line = bytes.split(separator: 0x0A).first.map { Array($0) } ?? []
        guard let request = try? JSONDecoder().decode(MacPairingRequest.self, from: Data(line)) else {
            return answerPairing(context, MacPairingReply(ok: false, error: "not a pairing request"))
        }
        if let problem = request.problem { return answerPairing(context, MacPairingReply(ok: false, error: problem)) }
        let services = self.services
        let loop = context.eventLoop
        services.log("mac server: \(request.name) asks to pair; asking the person")
        Task { [weak self] in
            let yes = await services.confirmPairing(request)
            let reply: MacPairingReply
            if yes {
                do {
                    let device = try services.devices.add(request, at: services.now())
                    services.log("mac server: paired \(device.id) (\(device.name))")
                    reply = MacPairingReply(ok: true, device: device.id, mac: services.macName)
                } catch {
                    reply = MacPairingReply(ok: false, error: "\(error)")
                }
            } else {
                reply = MacPairingReply(ok: false, error: "the person on the Mac said no")
            }
            loop.execute {
                guard let self, let context = self.context else { return }
                self.answerPairing(context, reply)
            }
        }
    }

    private func answerPairing(_ context: ChannelHandlerContext, _ reply: MacPairingReply) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = ((try? encoder.encode(reply)) ?? Data()) + Data([0x0A])
        write(context, Array(bytes)).whenComplete { [weak self] _ in
            guard let self, let context = self.context else { return }
            self.finish(context, status: reply.ok ? 0 : 1)
        }
    }

    // MARK: - Terminals

    private func attach(_ context: ChannelHandlerContext, _ target: MacTerminalTarget, wantReply: Bool) {
        let runner = services.runner
        if case .job(let job) = target {
            // The Hub has it open: the phone shares that terminal (D130).
            if runner.attaches.holder(of: job) == .hub, let shared = runner.hub?.share(job: job) {
                reply(context, wantReply, true)
                return share(context, shared, job: job)
            }
            guard runner.attaches.take(job, for: .bridge) else {
                _ = write(context, Array((BackgroundAttach.refusal + "\n").utf8), stream: .stdErr)
                return refuse(context, wantReply, "a second attach of \(job)", close: true)
            }
        }
        let release: @Sendable () -> Void = {
            if case .job(let job) = target { runner.attaches.release(job, by: .bridge) }
        }
        let argv: [String]
        switch runner.terminalCommand(target) {
        case .success(let made): argv = made
        case .failure(let why):
            release()
            _ = write(context, Array((why.description + "\n").utf8), stream: .stdErr)
            return refuse(context, wantReply, "attach", close: true)
        }
        let size = terminalSize ?? ("xterm-256color", 80, 24)
        var environment = runner.environment
        environment["TERM"] = size.term.isEmpty ? "xterm-256color" : size.term
        let list = environment.map { "\($0.key)=\($0.value)" }.sorted()
        guard let pty = MacPty(argv: argv, environment: list, directory: runner.home, columns: size.columns, rows: size.rows) else {
            release()
            return refuse(context, wantReply, "a terminal the system would not give", close: true)
        }
        reply(context, wantReply, true)
        mode = .terminal(pty)
        let device = connection.peer?.v1Peer?.device ?? ""
        let server = self.server
        server.opened(pty.pid, by: device)
        services.log("mac server: connection \(connection.number) opened a terminal (pid \(pty.pid))")
        let loop = context.eventLoop
        pty.start(send: { [weak self] bytes in
            guard let self else { return }
            // Waits for the channel to take them: the ssh window is the back-pressure.
            _ = try? loop.flatSubmit { () -> EventLoopFuture<Void> in
                guard let context = self.context else { return loop.makeSucceededVoidFuture() }
                return self.write(context, bytes)
            }.wait()
        }, done: { [weak self] status in
            release()
            server.closed(pty.pid, by: device)
            loop.execute {
                guard let self, let context = self.context else { return }
                self.finish(context, status: status)
            }
        })
    }

    private func share(_ context: ChannelHandlerContext, _ shared: MacSharedTerminal, job: String) {
        mode = .shared(shared, job: job)
        let loop = context.eventLoop
        services.log("mac server: connection \(connection.number) shares the Hub's terminal of \(job)")
        shared.start(send: { [weak self] bytes in
            loop.execute {
                guard let self, let context = self.context else { return }
                self.write(context, bytes)
            }
        }, ended: { [weak self] in
            loop.execute {
                guard let self, let context = self.context else { return }
                self.finish(context, status: 0)
            }
        })
    }

    // MARK: - Named actions

    private func run(_ context: ChannelHandlerContext, _ action: NodeAction) {
        let runner = services.runner
        let argv: [String]
        switch runner.command(action) {
        case .success(let made): argv = made
        case .failure(let why):
            _ = write(context, Array((why.description + "\n").utf8), stream: .stdErr)
            return finish(context, status: 2)
        }
        services.log("mac server: connection \(connection.number) runs \(action.name)")
        oneShot(context) {
            let result = MacProcess.run(argv, environment: runner.environmentList, directory: runner.home, deadline: 60)
            return (Array(result.output.utf8), result.status)
        }
    }

    private func oneShot(_ context: ChannelHandlerContext, _ work: @escaping @Sendable () -> ([UInt8], Int32)) {
        mode = .done
        let loop = context.eventLoop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (output, status) = work()
            loop.execute {
                guard let self, let context = self.context else { return }
                self.write(context, output).whenComplete { _ in
                    guard let context = self.context else { return }
                    self.finish(context, status: status)
                }
            }
        }
    }

    // MARK: - Bytes

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data, message.type == .channel else { return }
        let bytes = Array(buffer.readableBytesView)
        switch mode {
        case .v1: receiveV1(context, bytes)
        case .terminal(let pty): pty.write(bytes)
        case .shared(let shared, _): shared.write(bytes)
        case .pairing(var collected):
            collected += bytes
            // A pairing request is small: more than this is not one.
            if collected.count > 16 * 1024 { return finish(context, status: 1) }
            if collected.contains(0x0A) { pair(context, collected) } else { mode = .pairing(collected) }
        case .idle, .done: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        stopV1()
        switch mode {
        // The tmux client goes with the channel: no orphan (S-S).
        case .terminal(let pty): pty.hangUp()
        case .shared(let shared, _): shared.stop()
        default: break
        }
        mode = .done
        self.context = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func send(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        _ = write(context, bytes)
    }

    /// In pieces of at most 32 KiB: swift-nio-ssh does not split a write larger
    /// than the peer's window, and one would never leave (S-R).
    @discardableResult
    private func write(_ context: ChannelHandlerContext, _ bytes: [UInt8], stream: SSHChannelData.DataType = .channel) -> EventLoopFuture<Void> {
        guard context.channel.isActive else { return context.eventLoop.makeSucceededVoidFuture() }
        var last = context.eventLoop.makeSucceededVoidFuture()
        for piece in V1Frame.pieces(bytes) {
            var buffer = context.channel.allocator.buffer(capacity: piece.count)
            buffer.writeBytes(piece)
            last = context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: stream, data: .byteBuffer(buffer))))
        }
        return last
    }

    private func reply(_ context: ChannelHandlerContext, _ wanted: Bool, _ ok: Bool) {
        guard wanted else { return }
        context.channel.triggerUserOutboundEvent(ok ? ChannelSuccessEvent() as Any : ChannelFailureEvent() as Any, promise: nil)
    }

    private func refuse(_ context: ChannelHandlerContext, _ wanted: Bool, _ what: String, close: Bool) {
        services.log("mac server: connection \(connection.number) refused: \(what)")
        reply(context, wanted, false)
        if close {
            mode = .done
            context.close(promise: nil)
        }
    }

    private func finish(_ context: ChannelHandlerContext, status: Int32) {
        stopV1()
        mode = .done
        guard context.channel.isActive else { return }
        context.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: Int(status))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
