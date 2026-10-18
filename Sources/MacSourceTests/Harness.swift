#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
import LampBoardNodeLink
import ProtocolConformance
import TestKit

/// A switch the tests flip, read by the server on its own threads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// The time the server reads, moved by the tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var now: Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    func advance(_ seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
}

/// The Mac's server in this process, on loopback, with a home of its own, one
/// paired phone, and a tmux server of its own (`-L lb-mac-…`): never the
/// person's tmux, never `~/.lampboard`.
@available(macOS 15.0, *)
final class MacHarness: @unchecked Sendable {
    let home: String
    let devices: MacDevices
    let pairing = MacPairingWindow()
    let source: MacV1Source
    let server: MacSSHServer
    let port: Int
    let hostKey: NodeHostKey
    let read = ReadKey.generate()
    let action = ActionKey.generate()
    let deviceId: String
    let terminals: Flag
    let confirm = Flag(true)
    let clock = TestClock()
    let tmuxSocket: String
    let tmux: String?
    let attaches = MacAttachLedger()
    let hub: FakeHub
    private var made = 0

    static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init(terminalsOn: Bool = false) throws {
        home = MacFixtures.temporaryDirectory("home")
        devices = MacDevices(directory: home + "/.lampboard/mobile")
        terminals = Flag(terminalsOn)
        tmux = Self.tmuxPath()
        tmuxSocket = "lb-mac-\(getpid())-\(UInt16.random(in: 0...UInt16.max))"
        hub = FakeHub()
        let device = try devices.add(MacPairingRequest(name: "Example iPhone", readKey: read.publicKey, actionKey: action.publicKey),
                                     at: Date())
        deviceId = device.id
        let devices = self.devices
        let source = MacV1Source(
            identity: MacFixtures.mac, version: "2.4.0-test", startedAt: Date(),
            actions: MacSourceActions(
                perform: { _, _ in nil },
                devices: { request in
                    switch request.action {
                    case .list: return .success(devices.v1Devices)
                    case .revoke:
                        guard let id = request.device, (try? devices.revoke(id)) == true else {
                            return .failure(V1Failure(.notFound, "no device"))
                        }
                        return .success(devices.v1Devices)
                    }
                }
            ),
            retention: 100
        )
        self.source = source
        let key = try MacHostKey.loadOrMake(MacHostKey.FileStore(path: home + "/.lampboard/mobile/host_key"))
        hostKey = try NodeHostKey(openSSH: MacHostKey.openSSH(key))
        let bin = home + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try Self.script(bin + "/shell", "#!/bin/sh\nexec /bin/sh -c \"$2\"\n")
        try Self.script(bin + "/claude", """
        #!/bin/sh
        echo "$*" >> "$HOME/attaches.log"
        stty raw -echo
        exec cat "$LB_BIG"
        """)
        let environment = [
            "PATH": bin + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": home, "SHELL": bin + "/shell",
            "LB_BIG": home + "/big.bin", "TERM": "xterm-256color",
        ]
        let runner = MacRunner(
            tmux: [tmux ?? "/usr/bin/tmux", "-L", tmuxSocket], environment: environment, home: home,
            hub: hub, palette: { Array(#"{"theme":"example"}"#.utf8) }, attaches: attaches
        )
        let terminals = self.terminals, confirm = self.confirm, clock = self.clock
        server = MacSSHServer(
            configuration: MacSSHServer.Configuration(hostKey: key, hosts: ["127.0.0.1"], keepaliveIdle: 10),
            services: MacSSHServer.Services(
                source: source, devices: devices, pairing: pairing, runner: runner,
                terminalsOn: { terminals.on }, confirmPairing: { _ in confirm.on }, macName: "Example Mac",
                log: { line in
                    if ProcessInfo.processInfo.environment["LB_DEBUG"] != nil { FileHandle.standardError.write(Data((line + "\n").utf8)) }
                },
                now: { clock.now }
            )
        )
        port = try server.start()
        made = MacProvoker.provoke(source, count: 3, made: made, at: Date())
    }

    static func script(_ path: String, _ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    var endpoint: NodeEndpoint { NodeEndpoint(host: "127.0.0.1", port: port, user: MacBridge.user) }

    func provoke(_ count: Int) { made = MacProvoker.provoke(source, count: count, made: made, at: Date()) }

    func readConnection(key: ReadKey? = nil) throws -> ReadConnection {
        let endpoint = self.endpoint, hostKey = self.hostKey, key = key ?? read
        return try Blocking.run(20) { try await NodeLink.read(endpoint, trust: .pinned(hostKey), key: key) }
    }

    func actionConnection() throws -> ActionConnection {
        let endpoint = self.endpoint, hostKey = self.hostKey, key = action
        return try Blocking.run(20) { try await NodeLink.act(endpoint, trust: .pinned(hostKey), key: key) }
    }

    var invitation: MacPairingInvitation {
        let (code, _) = pairing.open(at: clock.now)
        return MacPairingInvitation(name: "Example Mac", hostKey: hostKey.openSSH, addresses: ["127.0.0.1"], port: port, code: code)
    }

    // MARK: - tmux of the harness's own

    @discardableResult
    func tmuxRun(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let tmux else { return (127, "") }
        // The person's own tmux server runs in UTF-8; the bridge's client must ask for it with -u.
        let result = MacProcess.run([tmux, "-L", tmuxSocket, "-f", "/dev/null"] + arguments,
                                    environment: ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME=" + home,
                                                  "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "TERM=xterm-256color"])
        return (result.status, result.output)
    }

    var tmuxClients: Int {
        tmuxRun(["list-clients", "-F", "#{client_pid}"]).output.split(separator: "\n").count
    }

    func stop() {
        server.stop()
        tmuxRun(["kill-server"])
        try? FileManager.default.removeItem(atPath: home)
    }
}

/// The Hub's terminal for a job, as the bridge shares it: what it is sent is
/// echoed back, prefixed, so the test sees both directions.
final class FakeHub: MacHubTerminals, @unchecked Sendable {
    final class Terminal: MacSharedTerminal, @unchecked Sendable {
        private let lock = NSLock()
        private var sender: (@Sendable ([UInt8]) -> Void)?
        private(set) var stopped = false
        func start(send: @escaping @Sendable ([UInt8]) -> Void, ended: @escaping @Sendable () -> Void) {
            lock.lock(); sender = send; lock.unlock()
            send(Array("hub screen\r\n".utf8))
        }
        func write(_ bytes: [UInt8]) {
            lock.lock(); let send = sender; lock.unlock()
            send?(Array("hub got: ".utf8) + bytes)
        }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }

    private let lock = NSLock()
    private var open: [String: Terminal] = [:]

    func openInHub(_ job: String) -> Terminal {
        let terminal = Terminal()
        lock.lock(); open[job] = terminal; lock.unlock()
        return terminal
    }

    func share(job: String) -> MacSharedTerminal? {
        lock.lock()
        defer { lock.unlock() }
        return open[job]
    }
}

/// A NodeLink channel as the conformance battery reads it.
final class ChannelStream: V1ByteStream, @unchecked Sendable {
    private let channel: NodeByteChannel
    private let closeConnection: @Sendable () async -> Void
    private let condition = NSCondition()
    private var buffer: [UInt8] = []
    private var ended = false

    init(_ channel: NodeByteChannel, closeConnection: @escaping @Sendable () async -> Void) {
        self.channel = channel
        self.closeConnection = closeConnection
        let inbound = channel.inbound
        Task.detached { [weak self] in
            for await chunk in inbound { self?.append(chunk) }
            self?.markEnded()
        }
    }

    func write(_ bytes: [UInt8]) throws {
        let channel = self.channel
        try Blocking.run(15) { try await channel.write(bytes) }
    }

    func read(timeout: TimeInterval) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty && !ended {
            if !condition.wait(until: deadline) { break }
        }
        if !buffer.isEmpty {
            defer { buffer = [] }
            return buffer
        }
        return ended ? nil : []
    }

    /// Everything until the channel ends or `timeout` passes.
    func drain(timeout: TimeInterval, until enough: ([UInt8]) -> Bool = { _ in false }) -> [UInt8] {
        var all: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let piece = try? read(timeout: 0.2) else { break }
            all += piece
            if enough(all) { break }
        }
        return all
    }

    func close() {
        let channel = self.channel, closeConnection = self.closeConnection
        _ = try? Blocking.run(10) {
            await channel.close()
            await closeConnection()
        }
    }

    private func append(_ chunk: [UInt8]) {
        condition.lock()
        buffer += chunk
        condition.broadcast()
        condition.unlock()
    }

    private func markEnded() {
        condition.lock()
        ended = true
        condition.broadcast()
        condition.unlock()
    }
}

/// The Mac's server reached over a real ssh, as the conformance battery's
/// target: every connection a new one, with the phone's key of that role.
@available(macOS 15.0, *)
final class MacSSHTarget: V1ConformanceTarget {
    let name = "the Mac's server over ssh"
    let pingInterval: TimeInterval = 0.5
    let harness: MacHarness

    init(_ harness: MacHarness) { self.harness = harness }

    func connect(role: V1Role) throws -> V1ByteStream {
        let harness = self.harness
        switch role {
        case .read:
            let connection = try harness.readConnection()
            let channel = try Blocking.run(15) { try await connection.openV1() }
            return ChannelStream(channel) { await connection.close() }
        case .action:
            let connection = try harness.actionConnection()
            let channel = try Blocking.run(15) { try await connection.openV1() }
            return ChannelStream(channel) { await connection.close() }
        }
    }

    func provoke(_ count: Int) throws { harness.provoke(count) }
}
