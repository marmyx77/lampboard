#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
@_spi(Probe) import LampBoardNodeLink
import TestKit

/// The doors of the Mac's server, each tried with the wrong key (the gate
/// «Server ssh del Mac» and «Chiavi ristrette» of §6.2).
enum MacServerSuite {

    static func suite(_ harness: MacHarness) -> TestSuite {
        TestSuite("The Mac's ssh server", [

            TestCase("A paired read key gets v1 and its hello says what the Mac is") { t in
                do {
                    let connection = try harness.readConnection()
                    let channel = try Blocking.run(15) { try await connection.openV1() }
                    let stream = ChannelStream(channel) { await connection.close() }
                    try stream.write(V1Frame.encode(Array(#"{"id":1,"op":"hello","protocol":1,"client":"test"}"#.utf8)))
                    let reply = String(decoding: stream.drain(timeout: 5) { String(decoding: $0, as: UTF8.self).contains("\"hello\"") },
                                       as: UTF8.self)
                    t.expect(reply.contains("\"kind\":\"mac\""), "a Mac: \(reply.prefix(200))")
                    t.expect(reply.contains("\"role\":\"read\""), "seen as the read key")
                    stream.close()
                } catch {
                    t.fail("\(error)")
                }
            },

            TestCase("A key the Mac never paired does not get in") { t in
                t.expectNotNil(refusal { _ = try harness.readConnection(key: ReadKey.generate()) }, "refused")
            },

            TestCase("A Mac presenting another host key is refused before anything is sent") { t in
                let other = try? NodeHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHZ4VbAqpzRzMnFmsr3xOrkdgD5Q4XU9Fw2y9U6vjn8x")
                let endpoint = harness.endpoint, key = harness.read
                guard let other else { return t.fail("the example key does not read") }
                do {
                    _ = try Blocking.run(15) { try await NodeLink.read(endpoint, trust: .pinned(other), key: key) }
                    t.fail("connected to a Mac with another key")
                } catch let error as NodeLinkError {
                    if case .hostKeyMismatch = error {} else { t.fail("not a mismatch: \(error)") }
                } catch {
                    t.fail("\(error)")
                }
            },

            TestCase("The read key cannot open a terminal, an action, or anything but v1") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                guard let connection = try? harness.readConnection() else { return t.fail("no connection") }
                for line in ["palette", "background", MacRequest.action(.look).line ?? "", "/bin/sh -c id", "pair"] {
                    t.expect(closedEmpty { try Blocking.run(15) { try await connection.openAnything(line) } }, "refused: \(line.prefix(30))")
                }
                let size = TerminalSize(columns: 80, rows: 24)!
                t.expectNotNil(refusal {
                    _ = try Blocking.run(15) { try await connection.openTerminalAnyway(command: MacRequest.attach(.tmux(session: "alpha")).line!, size: size) }
                }, "no terminal for the read key")
                _ = try? Blocking.run(10) { await connection.close() }
            },

            TestCase("With the switch off the action key gets v1 and the devices, nothing else (Q17)") { t in
                harness.terminals.on = false
                guard let connection = try? harness.actionConnection() else { return t.fail("no connection") }
                t.expectNotNil(refusal { _ = try Blocking.run(15) { try await connection.runOnMac(.look) } }, "no action")
                t.expectNotNil(refusal {
                    _ = try Blocking.run(15) { try await connection.openMacTerminal(.tmux(session: "alpha"), size: TerminalSize(columns: 80, rows: 24)!) }
                }, "no terminal")
                t.expectNotNil(try? Blocking.run(15) { try await connection.openV1() }, "v1 still opens")
                _ = try? Blocking.run(10) { await connection.close() }
            },

            TestCase("With the switch on, an unnamed command is still refused") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                guard let connection = try? harness.actionConnection() else { return t.fail("no connection") }
                for line in ["/bin/sh -c id", "id", "attach alpha", "action " + Data(#"{"name":"projects"}"#.utf8).base64EncodedString()] {
                    t.expectNotNil(refusal { _ = try Blocking.run(15) { try await connection.run(line) } }, "refused: \(line.prefix(30))")
                }
                _ = try? Blocking.run(10) { await connection.close() }
            },

            TestCase("Pairing: the code once, inside its window, after the person said yes") { t in
                let invitation = harness.invitation
                let request = MacPairingRequest(name: "Example iPad", readKey: ReadKey.generate().publicKey,
                                                actionKey: ActionKey.generate().publicKey)
                let reply = try? Blocking.run(30) { try await NodeLink.pair(invitation, address: "127.0.0.1", request: request) }
                t.expectEqual(reply?.ok, true, "paired: \(String(describing: reply))")
                t.expect(reply?.device.map { harness.devices.all.map(\.id).contains($0) } ?? false, "and listed on the Mac")
                let again = MacPairingRequest(name: "Another", readKey: ReadKey.generate().publicKey, actionKey: ActionKey.generate().publicKey)
                t.expectNotNil(refusal { _ = try Blocking.run(30) { try await NodeLink.pair(invitation, address: "127.0.0.1", request: again) } },
                               "the same code a second time")
            },

            TestCase("Pairing: outside the window, with three wrong codes, or with a no, nothing is paired") { t in
                let before = harness.devices.all.count
                let late = harness.invitation
                harness.clock.advance(121)
                let request = MacPairingRequest(name: "Late", readKey: ReadKey.generate().publicKey, actionKey: ActionKey.generate().publicKey)
                t.expectNotNil(refusal { _ = try Blocking.run(30) { try await NodeLink.pair(late, address: "127.0.0.1", request: request) } }, "late")
                let right = harness.invitation
                for _ in 0..<3 {
                    let wrong = MacPairingInvitation(name: right.name, hostKey: right.hostKey, addresses: right.addresses,
                                                     port: right.port, code: MacPairingCode.make())
                    _ = refusal { _ = try Blocking.run(30) { try await NodeLink.pair(wrong, address: "127.0.0.1", request: request) } }
                }
                t.expectNotNil(refusal { _ = try Blocking.run(30) { try await NodeLink.pair(right, address: "127.0.0.1", request: request) } },
                               "the right code after three wrong ones")
                harness.confirm.on = false
                defer { harness.confirm.on = true }
                let fresh = harness.invitation
                let said = try? Blocking.run(30) { try await NodeLink.pair(fresh, address: "127.0.0.1", request: request) }
                t.expectEqual(said?.ok, false, "the person said no")
                t.expectEqual(harness.devices.all.count, before, "nothing paired")
            },

            TestCase("A device forgotten on the Mac is refused at its next connection") { t in
                let read = ReadKey.generate()
                guard let device = try? harness.devices.add(
                    MacPairingRequest(name: "Soon gone", readKey: read.publicKey, actionKey: ActionKey.generate().publicKey), at: Date())
                else { return t.fail("not added") }
                t.expectNotNil(try? harness.readConnection(key: read), "in while paired")
                _ = try? harness.devices.revoke(device.id)
                t.expectNotNil(refusal { _ = try harness.readConnection(key: read) }, "out once forgotten")
            },

            TestCase("Random bytes before authentication: 60 connections, the server stays up") { t in
                var generator = SystemRandomNumberGenerator()
                for index in 0..<60 {
                    let garbage = (0..<Int.random(in: 1...4096, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
                    // Half begin like an ssh client would, then go wrong.
                    let bytes = index % 2 == 0 ? Array("SSH-2.0-OpenSSH_9.6\r\n".utf8) + garbage : garbage
                    RawTCP.send(bytes, to: harness.port)
                }
                t.expectNotNil(try? harness.readConnection(), "a paired phone still gets in")
            },
        ])
    }

    /// Whether a channel was refused: never opened, or ended at once without
    /// a byte of output (Citadel's exec opens before the server answers).
    static func closedEmpty(_ open: () throws -> NodeByteChannel) -> Bool {
        guard let channel = try? open() else { return true }
        let stream = ChannelStream(channel) {}
        let bytes = stream.drain(timeout: 5)
        let ended = (try? stream.read(timeout: 1)) == nil
        stream.close()
        return bytes.isEmpty && ended
    }

    /// The error a refused operation threw, or `nil` when it went through.
    static func refusal(_ body: () throws -> Void) -> Error? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }
}

/// A TCP connection that says something and leaves.
enum RawTCP {
    static func send(_ bytes: [UInt8], to port: Int) {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return }
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        usleep(20_000)
    }
}
