import Foundation
import LampBoardCore
import LampBoardMacSource
@_spi(Probe) import LampBoardNodeLink
import ProtocolConformance
import TestKit

/// The Mac as a source for the phone (W5), on the real app: its own ssh server
/// in a fake home, a phone paired before launch, the column's rows served as
/// `v1` from the hooks the app hears. The phone is NodeLink, the same client the
/// iPhone runs (the gates «Un protocollo, due sorgenti», «Chiavi ristrette» and
/// «Server ssh del Mac» of §6.2, against the app itself).
enum MobileE2ESuite {

    static let folder = "/tmp/lampboard-e2e/project-mobile"
    static func sid(_ n: Int) -> String { String(format: "e5e5e5e5-0000-4000-8000-%012ld", n) }

    final class Phone {
        let read = ReadKey.generate()
        let action = ActionKey.generate()
    }

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        let app = AppUnderTest(binaryURL: binaryURL, port: port)
        let mobilePort = Int(port) &+ 2000
        let phone = Phone()
        app.extraEnvironment = ["LAMPBOARD_MOBILE_PORT": String(mobilePort)]
        app.beforeLaunch = { home in
            // Paired before the app starts: the server listens because a device is.
            let devices = MacDevices(directory: home.appendingPathComponent(".lampboard/mobile").path)
            _ = try? devices.add(MacPairingRequest(name: "Example iPhone", readKey: phone.read.publicKey,
                                                   actionKey: phone.action.publicKey), at: Date())
        }
        var started = false
        func ready() -> Bool {
            if started { return app.isRunning }
            started = true
            guard (try? app.start()) != nil else { return false }
            app.writeIDELock(port: 40061, folders: [folder])
            return true
        }
        func hostKey() -> NodeHostKey? {
            let store = MacHostKey.FileStore(path: app.home.appendingPathComponent(".lampboard/mobile/host_key").path)
            guard store.load() != nil, let key = try? MacHostKey.loadOrMake(store) else { return nil }
            return try? NodeHostKey(openSSH: MacHostKey.openSSH(key))
        }
        let endpoint = NodeEndpoint(host: "127.0.0.1", port: mobilePort, user: MacBridge.user)

        guard #available(macOS 15.0, *) else {
            return TestSuite("iPhone & iPad on the real app", [TestCase("needs macOS 15") { t in t.fail("macOS 15 or later") }])
        }
        let target = AppTarget(app: app, endpoint: endpoint, hostKey: { hostKey() }, phone: phone)
        return TestSuite("iPhone & iPad on the real app", [

            TestCase("A paired read key reads the column the hooks made, as a Mac") { t in
                guard ready() else { return t.fail("the app did not start") }
                app.sendHook(HookPayloads.sessionStart(sessionId: sid(1), cwd: folder))
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: sid(1), cwd: folder))
                guard let key = hostKey() else { return t.fail("no host key in the fake home") }
                let seen = app.waitUntil(timeout: 15) {
                    guard let connection = try? Blocking.run(20, { try await NodeLink.read(endpoint, trust: .pinned(key), key: phone.read) }),
                          let channel = try? Blocking.run(15, { try await connection.openV1() }) else { return false }
                    let stream = E2EChannelStream(channel) { await connection.close() }
                    defer { stream.close() }
                    try? stream.write(V1Frame.encode(Array(#"{"id":1,"op":"hello","protocol":1,"client":"e2e"}"#.utf8)))
                    try? stream.write(V1Frame.encode(Array(#"{"id":2,"op":"state"}"#.utf8)))
                    var text = ""
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline, !text.contains("\"rows\""), let piece = try? stream.read(timeout: 0.5) {
                        text += String(decoding: piece, as: UTF8.self)
                    }
                    return text.contains(sid(1)) && text.contains(#""kind":"mac""#)
                }
                t.expect(seen, "the row reached the phone from the Mac")
            },

            TestCase("A key the Mac never paired, or the read key asking for a terminal, gets nothing") { t in
                guard ready(), let key = hostKey() else { return t.fail("the app did not start") }
                t.expect((try? Blocking.run(20) { try await NodeLink.read(endpoint, trust: .pinned(key), key: ReadKey.generate()) }) == nil,
                         "an unpaired key is refused")
                guard let connection = try? Blocking.run(20, { try await NodeLink.read(endpoint, trust: .pinned(key), key: phone.read) }) else {
                    return t.fail("the paired read key was refused")
                }
                let terminal = try? Blocking.run(20) {
                    try await connection.openTerminalAnyway(command: MacRequest.attach(.tmux(session: "e2e")).line!,
                                                            size: TerminalSize(columns: 80, rows: 24)!)
                }
                t.expectNil(terminal, "no terminal for the read key")
                _ = try? Blocking.run(10) { await connection.close() }
            },

            TestCase("With the switch off (Q17) the action key opens no terminal and runs no action") { t in
                guard ready(), let key = hostKey(),
                      let connection = try? Blocking.run(20, { try await NodeLink.act(endpoint, trust: .pinned(key), key: phone.action) })
                else { return t.fail("the paired action key was refused") }
                t.expect((try? Blocking.run(20) { try await connection.runOnMac(.look) }).map { $0.exitCode != 0 } ?? true, "no action")
                t.expectNil(try? Blocking.run(20) {
                    try await connection.openMacTerminal(.tmux(session: "e2e"), size: TerminalSize(columns: 80, rows: 24)!)
                }, "no terminal")
                _ = try? Blocking.run(10) { await connection.close() }
            },
        ] + V1Conformance.suite(against: target).cases.map { conformance in
            TestCase("v1 conformance against the app: " + conformance.name) { t in
                guard ready() else { return t.fail("the app did not start") }
                conformance.body(t)
            }
        } + [
            TestCase("The server stops with the app") { t in
                app.stop()
                t.expect((try? Blocking.run(10) { try await NodeLink.read(endpoint, trust: .firstUse, key: phone.read) }) == nil,
                         "nothing listens once the app is gone")
            },
        ])
    }

    /// The app's server as the conformance battery's target: the source made
    /// to change by hooks, one row at a time, as Claude Code changes it.
    @available(macOS 15.0, *)
    final class AppTarget: V1ConformanceTarget {
        let name = "the Mac app's server"
        let pingInterval: TimeInterval = 0.5
        private let app: AppUnderTest
        private let endpoint: NodeEndpoint
        private let hostKey: () -> NodeHostKey?
        private let phone: Phone
        private var made = 0

        init(app: AppUnderTest, endpoint: NodeEndpoint, hostKey: @escaping () -> NodeHostKey?, phone: Phone) {
            self.app = app
            self.endpoint = endpoint
            self.hostKey = hostKey
            self.phone = phone
        }

        func connect(role: V1Role) throws -> V1ByteStream {
            guard let key = hostKey() else { throw NodeLinkError.failed("no host key") }
            let endpoint = self.endpoint, phone = self.phone
            switch role {
            case .read:
                let connection = try Blocking.run(20) { try await NodeLink.read(endpoint, trust: .pinned(key), key: phone.read) }
                let channel = try Blocking.run(15) { try await connection.openV1() }
                return E2EChannelStream(channel) { await connection.close() }
            case .action:
                let connection = try Blocking.run(20) { try await NodeLink.act(endpoint, trust: .pinned(key), key: phone.action) }
                let channel = try Blocking.run(15) { try await connection.openV1() }
                return E2EChannelStream(channel) { await connection.close() }
            }
        }

        /// One hook per change, each on the next of three sessions, far enough
        /// apart that the app's column publishes each on its own.
        func provoke(_ count: Int) throws {
            for _ in 0..<count {
                made += 1
                let id = MobileE2ESuite.sid((made - 1) % 3 + 10)
                let payload = made % 2 == 0 ? HookPayloads.stop(sessionId: id, cwd: MobileE2ESuite.folder, message: "Done \(made).")
                                            : HookPayloads.userPromptSubmit(sessionId: id, cwd: MobileE2ESuite.folder)
                app.sendHook(payload)
                usleep(400_000)
            }
        }
    }
}

/// A NodeLink channel as the conformance battery reads it.
final class E2EChannelStream: V1ByteStream, @unchecked Sendable {
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
