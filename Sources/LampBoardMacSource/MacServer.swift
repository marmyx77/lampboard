#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import LampBoardCore
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// The ssh server inside the Mac app (§2.4, §2.6, S-R): its own port, paired
/// keys only, no shell, no command of the phone's own.
///
/// Who may do what is `MacPolicy`; what runs is `MacRunner`; what `v1` says is
/// the Core's `V1Service` over `MacV1Source`. This file only carries bytes and
/// keeps the doors: authentication, channels, keepalive.
public final class MacSSHServer: @unchecked Sendable {

    public struct Configuration: @unchecked Sendable {
        public var hostKey: NIOSSHPrivateKey
        /// The port to listen on; `0` for one the system picks.
        public var port: Int
        /// The addresses to listen on: every interface by default, so the LAN
        /// and the tailnet both reach it (§2.5).
        public var hosts: [String]
        /// TCP keepalive (E14): idle seconds, then `count` probes `interval`
        /// apart. A phone gone without a FIN is noticed in about twenty
        /// seconds, and its tmux client hung up.
        public var keepaliveIdle: Int
        public var keepaliveInterval: Int
        public var keepaliveCount: Int
        /// How often a `v1` channel looks for new events when nothing told it.
        public var pollInterval: TimeInterval

        public init(hostKey: NIOSSHPrivateKey, port: Int = 0, hosts: [String] = ["0.0.0.0"],
                    keepaliveIdle: Int = 10, keepaliveInterval: Int = 5, keepaliveCount: Int = 3,
                    pollInterval: TimeInterval = 0.25) {
            self.hostKey = hostKey
            self.port = port
            self.hosts = hosts
            self.keepaliveIdle = keepaliveIdle
            self.keepaliveInterval = keepaliveInterval
            self.keepaliveCount = keepaliveCount
            self.pollInterval = pollInterval
        }
    }

    /// What the server needs from the app.
    public struct Services: Sendable {
        public var source: MacV1Source
        public var devices: MacDevices
        public var pairing: MacPairingWindow
        public var runner: MacRunner
        /// «Terminal and actions from iPhone & iPad» (Q17): off by default.
        public var terminalsOn: @Sendable () -> Bool
        /// Asks the person, on the Mac, whether this device may pair: its name
        /// and the fingerprints of its keys. Nothing is paired without a yes.
        public var confirmPairing: @Sendable (MacPairingRequest) async -> Bool
        /// After the yes, the device's keys carried to the nodes the person
        /// ticked (W5, §2.4: `lampd devices add` over the Mac's own ssh). What
        /// comes back goes to the phone in the reply.
        public var carryToNodes: @Sendable (MacDevices.Device) async -> [MacPairedNode]
        /// The Mac's name, as the person gave it.
        public var macName: String
        public var log: @Sendable (String) -> Void
        public var now: @Sendable () -> Date

        public init(source: MacV1Source, devices: MacDevices, pairing: MacPairingWindow, runner: MacRunner,
                    terminalsOn: @escaping @Sendable () -> Bool, confirmPairing: @escaping @Sendable (MacPairingRequest) async -> Bool,
                    carryToNodes: @escaping @Sendable (MacDevices.Device) async -> [MacPairedNode] = { _ in [] },
                    macName: String, log: @escaping @Sendable (String) -> Void = { _ in },
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.source = source
            self.devices = devices
            self.pairing = pairing
            self.runner = runner
            self.terminalsOn = terminalsOn
            self.confirmPairing = confirmPairing
            self.carryToNodes = carryToNodes
            self.macName = macName
            self.log = log
            self.now = now
        }
    }

    public let configuration: Configuration
    public let services: Services
    public let throttle = MacAuthThrottle()
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var listeners: [Channel] = []
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var nextConnection = 0
    public private(set) var port: Int?

    public init(configuration: Configuration, services: Services, threads: Int = 2) {
        self.configuration = configuration
        self.services = services
        group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
    }

    /// Listens; returns the port. A port already taken is an error, said.
    @discardableResult
    public func start() throws -> Int {
        var bound: [Channel] = []
        var chosen = configuration.port
        for host in configuration.hosts {
            let channel = try bootstrap().bind(host: host, port: chosen).wait()
            if chosen == 0 { chosen = channel.localAddress?.port ?? 0 }
            bound.append(channel)
        }
        lock.lock()
        listeners = bound
        port = chosen
        lock.unlock()
        services.log("mac server: listening on \(configuration.hosts.joined(separator: ", ")) port \(chosen), host key \(MacHostKey.fingerprint(openSSH: MacHostKey.openSSH(configuration.hostKey)))")
        return chosen
    }

    /// Stops listening, ends every connection and every terminal it opened.
    public func stop() {
        lock.lock()
        let all = listeners + Array(connections.values)
        listeners = []
        connections = [:]
        lock.unlock()
        for channel in all { try? channel.close().wait() }
        MacPty.living.hangUpAll()
        try? group.syncShutdownGracefully()
        services.log("mac server: stopped")
    }

    /// Ends the connections of one device at once (Forget, revoke).
    public func disconnect(device: String) {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for channel in all {
            channel.pipeline.handler(type: MacConnectionCloser.self).whenSuccess { closer in
                if closer.connection.peer?.v1Peer?.device == device { channel.close(promise: nil) }
            }
        }
    }

    /// The terminals each device has open now, by the pid of the bridge's
    /// child — tmux's own `#{client_pid}` (S-D): what `background` detaches.
    /// By device and not by connection, because the phone opens each terminal
    /// on a connection of its own.
    private var terminalsByDevice: [String: Set<pid_t>] = [:]

    func opened(_ pid: pid_t, by device: String) {
        lock.lock()
        terminalsByDevice[device, default: []].insert(pid)
        lock.unlock()
    }

    func closed(_ pid: pid_t, by device: String) {
        lock.lock()
        terminalsByDevice[device]?.remove(pid)
        lock.unlock()
    }

    public func terminals(of device: String) -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return terminalsByDevice[device] ?? []
    }

    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    private func bootstrap() -> ServerBootstrap {
        let configuration = self.configuration
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(MacKeepalive.idle, value: SocketOptionValue(configuration.keepaliveIdle))
            .childChannelOption(MacKeepalive.interval, value: SocketOptionValue(configuration.keepaliveInterval))
            .childChannelOption(MacKeepalive.count, value: SocketOptionValue(configuration.keepaliveCount))
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture { try self.accept(channel) }
            }
    }

    private func accept(_ channel: Channel) throws {
        lock.lock()
        nextConnection += 1
        let number = nextConnection
        connections[ObjectIdentifier(channel)] = channel
        lock.unlock()
        let address = channel.remoteAddress?.ipAddress ?? "?"
        let connection = MacConnection(number: number, address: address)
        let delegate = MacAuthDelegate(server: self, connection: connection)
        let ssh = NIOSSHHandler(
            role: .server(SSHServerConfiguration(hostKeys: [configuration.hostKey], userAuthDelegate: delegate)),
            allocator: channel.allocator
        ) { [weak self] child, type in
            guard let self, case .session = type, connection.peer != nil else {
                return child.eventLoop.makeFailedFuture(MacSourceError.refused("only session channels, after authentication"))
            }
            return child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(MacChannel(server: self, connection: connection))
            }
        }
        let closer = MacConnectionCloser(connection: connection) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.connections[ObjectIdentifier(channel)] = nil
            self.lock.unlock()
            self.services.log("mac server: connection \(number) ended")
        }
        try channel.pipeline.syncOperations.addHandlers(ssh, closer)
        services.log("mac server: connection \(number) from \(address)")
    }
}

/// One TCP connection: who authenticated, and the terminals it opened.
final class MacConnection: @unchecked Sendable {
    let number: Int
    let address: String
    private let lock = NSLock()
    private var _peer: MacPeer?

    init(number: Int, address: String) {
        self.number = number
        self.address = address
    }

    var peer: MacPeer? {
        get { lock.lock(); defer { lock.unlock() }; return _peer }
        set { lock.lock(); _peer = newValue; lock.unlock() }
    }

}

/// Paired keys for `lampboard`, the code for `pair` inside its window, nothing
/// else; every refusal held a little longer than the one before (§2.10).
final class MacAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    private weak var server: MacSSHServer?
    private let connection: MacConnection

    init(server: MacSSHServer, connection: MacConnection) {
        self.server = server
        self.connection = connection
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey, .password] }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard let server else { return responsePromise.succeed(.failure) }
        let now = server.services.now()
        let (peer, why) = judge(request, server: server, at: now)
        let address = connection.address
        if let peer {
            connection.peer = peer
            server.throttle.succeeded(address)
            if case .device(let id, _) = peer { server.services.devices.seen(id, at: now) }
            server.services.log("mac server: connection \(connection.number) is \(Self.describe(peer))")
            return responsePromise.succeed(.success)
        }
        // The delay is the one earned before this refusal, so a first mistake
        // costs nothing and a scan slows to a crawl.
        let delay = server.throttle.delay(for: address, at: now)
        server.throttle.failed(address, at: now)
        server.services.log("mac server: connection \(connection.number) refused (\(request.username)): \(why)")
        guard delay > 0 else { return responsePromise.succeed(.failure) }
        responsePromise.futureResult.eventLoop.scheduleTask(in: .milliseconds(Int64(delay * 1000))) {
            responsePromise.succeed(.failure)
        }
    }

    private func judge(_ request: NIOSSHUserAuthenticationRequest, server: MacSSHServer, at now: Date) -> (MacPeer?, String) {
        switch (request.username, request.request) {
        case (MacBridge.user, .publicKey(let key)):
            guard String(openSSHPublicKey: key.publicKey).hasPrefix("ecdsa-sha2-nistp256 ") else {
                return (nil, "only P-256 keys")
            }
            guard let found = server.services.devices.role(of: key.publicKey) else { return (nil, "a key this Mac never paired") }
            return (.device(id: found.device, role: found.role), "")
        case (MacBridge.pairUser, .password(let password)):
            switch server.services.pairing.attempt(password.password, at: now) {
            case .accepted: return (.pairing, "")
            case .refused(let why): return (nil, why)
            }
        case (MacBridge.user, _):
            return (nil, "a paired key only")
        case (MacBridge.pairUser, _):
            return (nil, "the pairing code only")
        default:
            return (nil, "no such account")
        }
    }

    static func describe(_ peer: MacPeer) -> String {
        switch peer {
        case .pairing: return "pairing"
        case .device(let id, let role): return "\(id) with its \(role.rawValue) key"
        }
    }
}

/// Last in each connection's pipeline: forgets the connection when it ends,
/// and closes it on an error rather than letting it hang.
final class MacConnectionCloser: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    let connection: MacConnection
    private let ended: () -> Void

    init(connection: MacConnection, ended: @escaping () -> Void) {
        self.connection = connection
        self.ended = ended
    }

    func channelInactive(context: ChannelHandlerContext) {
        ended()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// The keepalive options, whose names differ between the two systems.
enum MacKeepalive {
    #if canImport(Darwin)
    static let idle = ChannelOptions.Types.SocketOption(level: IPPROTO_TCP, name: TCP_KEEPALIVE)
    #else
    static let idle = ChannelOptions.Types.SocketOption(level: SocketOptionLevel(IPPROTO_TCP), name: TCP_KEEPIDLE)
    #endif
    static let interval = ChannelOptions.Types.SocketOption(level: SocketOptionLevel(IPPROTO_TCP), name: TCP_KEEPINTVL)
    static let count = ChannelOptions.Types.SocketOption(level: SocketOptionLevel(IPPROTO_TCP), name: TCP_KEEPCNT)
}
