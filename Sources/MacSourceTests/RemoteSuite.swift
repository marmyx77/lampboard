import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
@_spi(Probe) import LampBoardNodeLink
import ProtocolConformance
import TestKit

/// The fake phone on another machine (T1-linux): the same checks, against the
/// real app on the test Mac, over the network, with keys made here.
///
///   MacSourceTests keys <dir>                    read.key/.pub and action.key/.pub
///   MacSourceTests devices <keys dir> <out dir>  the devices.json that pairs them
///   MacSourceTests remote --host H --port P --host-key F --keys D --provoke CMD
///                         [--tmux S] [--pair-code C] [filter]
///
/// `--provoke CMD` is run as `/bin/sh -c "CMD <count>"` and must make the Mac's
/// column change that many times (hooks sent to the app under test).
@available(macOS 15.0, *)
enum RemoteMac {

    struct Options {
        let endpoint: NodeEndpoint
        let hostKey: NodeHostKey
        let read: ReadKey
        let action: ActionKey
        let provoke: String
        let tmux: String?
        let pairCode: String?
    }

    static func suites(_ options: Options) -> [TestSuite] {
        [V1Conformance.suite(against: Target(options)), doors(options)]
    }

    static func doors(_ options: Options) -> TestSuite {
        let endpoint = options.endpoint, hostKey = options.hostKey
        func read(_ key: ReadKey) throws -> ReadConnection {
            try Blocking.run(30) { try await NodeLink.read(endpoint, trust: .pinned(hostKey), key: key) }
        }
        func act() throws -> ActionConnection {
            try Blocking.run(30) { try await NodeLink.act(endpoint, trust: .pinned(hostKey), key: options.action) }
        }
        var cases = [
            TestCase("Over the network: a key the Mac never paired gets nothing") { t in
                t.expectNotNil(MacServerSuite.refusal { _ = try read(ReadKey.generate()) }, "refused")
            },
            TestCase("Over the network: the read key gets v1 and no terminal, no action") { t in
                guard let connection = try? read(options.read) else { return t.fail("the paired read key was refused") }
                t.expect(MacServerSuite.closedEmpty { try Blocking.run(15) { try await connection.openAnything("palette") } }, "no palette")
                t.expect(MacServerSuite.closedEmpty { try Blocking.run(15) { try await connection.openAnything(MacRequest.action(.look).line!) } },
                         "no action")
                t.expectNotNil(MacServerSuite.refusal {
                    _ = try Blocking.run(15) {
                        try await connection.openTerminalAnyway(command: MacRequest.attach(.tmux(session: "x")).line!, size: TerminalSize(columns: 80, rows: 24)!)
                    }
                }, "no terminal")
                _ = try? Blocking.run(10) { await connection.close() }
            },
        ]
        if let session = options.tmux {
            cases.append(TestCase("Over the network: the Mac's tmux through the bridge, ❯ intact, and the background rule") { t in
                guard let connection = try? act() else { return t.fail("the paired action key was refused") }
                do {
                    let terminal = try Blocking.run(20) {
                        try await connection.openMacTerminal(.tmux(session: session), size: TerminalSize(columns: 100, rows: 30)!)
                    }
                    let stream = ChannelStream(terminal) {}
                    let screen = String(decoding: stream.drain(timeout: 8) { String(decoding: $0, as: UTF8.self).contains("❯") }, as: UTF8.self)
                    t.expect(screen.contains("❯"), "❯ intact through the bridge")
                    let answer = try Blocking.run(20) { try await connection.backgroundOnMac() }
                    t.expect(answer.output.contains(#""detached":1"#), "the phone's client detached: \(answer.output)")
                    stream.close()
                } catch {
                    t.fail("\(error)")
                }
                _ = try? Blocking.run(10) { await connection.close() }
            })
        }
        if let code = options.pairCode {
            cases.append(TestCase("Over the network: pairing with the QR code's invitation, then reading as the new device") { t in
                let invitation = MacPairingInvitation(name: "test Mac", hostKey: hostKey.openSSH, addresses: [endpoint.host],
                                                      port: endpoint.port, code: code)
                let newRead = ReadKey.generate()
                let request = MacPairingRequest(name: "Example Linux phone", readKey: newRead.publicKey, actionKey: ActionKey.generate().publicKey)
                let reply = try? Blocking.run(60) { try await NodeLink.pair(invitation, address: endpoint.host, request: request) }
                t.expectEqual(reply?.ok, true, "paired: \(String(describing: reply))")
                t.expectNotNil(try? read(newRead), "and the new device's read key gets in")
                t.expectNotNil(MacServerSuite.refusal {
                    _ = try Blocking.run(60) { try await NodeLink.pair(invitation, address: endpoint.host, request: request) }
                }, "the code does not work twice")
            })
        }
        return TestSuite("The Mac's server over the network", cases)
    }

    final class Target: V1ConformanceTarget {
        let name = "the Mac app's server over the network"
        let pingInterval: TimeInterval = 0.5
        private let options: Options

        init(_ options: Options) { self.options = options }

        func connect(role: V1Role) throws -> V1ByteStream {
            let endpoint = options.endpoint, hostKey = options.hostKey, read = options.read, action = options.action
            switch role {
            case .read:
                let connection = try Blocking.run(30) { try await NodeLink.read(endpoint, trust: .pinned(hostKey), key: read) }
                let channel = try Blocking.run(15) { try await connection.openV1() }
                return ChannelStream(channel) { await connection.close() }
            case .action:
                let connection = try Blocking.run(30) { try await NodeLink.act(endpoint, trust: .pinned(hostKey), key: action) }
                let channel = try Blocking.run(15) { try await connection.openV1() }
                return ChannelStream(channel) { await connection.close() }
            }
        }

        func provoke(_ count: Int) throws {
            let result = MacProcess.run(["/bin/sh", "-c", options.provoke + " \(count)"],
                                        environment: ["PATH=/usr/local/bin:/usr/bin:/bin", "HOME=" + NSHomeDirectory()], deadline: 120)
            guard result.status == 0 else { throw NodeLinkError.failed("provoke exited \(result.status): \(result.output)") }
        }
    }
}

/// The command lines of the remote mode.
enum RemoteCommands {
    static func option(_ arguments: [String], _ name: String) -> String? {
        guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func keys(_ directory: String) -> Int32 {
        let read = ReadKey.generate(), action = ActionKey.generate()
        for (name, raw, pub) in [("read", read.rawRepresentation, read.publicKey), ("action", action.rawRepresentation, action.publicKey)] {
            _ = FileManager.default.createFile(atPath: "\(directory)/\(name).key", contents: Data(raw.base64EncodedString().utf8),
                                               attributes: [.posixPermissions: 0o600])
            _ = FileManager.default.createFile(atPath: "\(directory)/\(name).pub", contents: Data((pub + "\n").utf8))
        }
        return 0
    }

    static func devices(_ keys: String, _ out: String) -> Int32 {
        let read = (try? String(contentsOfFile: keys + "/read.pub", encoding: .utf8)) ?? ""
        let action = (try? String(contentsOfFile: keys + "/action.pub", encoding: .utf8)) ?? ""
        let store = MacDevices(directory: out)
        do {
            _ = try store.add(MacPairingRequest(name: "Example Linux phone", readKey: read.trimmingCharacters(in: .whitespacesAndNewlines),
                                                actionKey: action.trimmingCharacters(in: .whitespacesAndNewlines)), at: Date())
            return 0
        } catch {
            FileHandle.standardError.write(Data("devices: \(error)\n".utf8))
            return 1
        }
    }

    @available(macOS 15.0, *)
    static func remote(_ arguments: [String]) -> Int32 {
        func raw(_ path: String) -> Data? {
            (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let host = option(arguments, "host"), let port = option(arguments, "port").flatMap(Int.init),
              let keyFile = option(arguments, "host-key"), let keys = option(arguments, "keys"), let provoke = option(arguments, "provoke"),
              let hostText = try? String(contentsOfFile: keyFile, encoding: .utf8), let hostKey = try? NodeHostKey(openSSH: hostText),
              let readRaw = raw(keys + "/read.key"), let actionRaw = raw(keys + "/action.key"),
              let read = try? ReadKey(rawRepresentation: readRaw), let action = try? ActionKey(rawRepresentation: actionRaw)
        else {
            FileHandle.standardError.write(Data("remote --host H --port P --host-key F --keys D --provoke CMD [--tmux S] [--pair-code C] [filter]\n".utf8))
            return 2
        }
        let options = RemoteMac.Options(endpoint: NodeEndpoint(host: host, port: port, user: MacBridge.user), hostKey: hostKey,
                                        read: read, action: action, provoke: provoke, tmux: option(arguments, "tmux"),
                                        pairCode: option(arguments, "pair-code"))
        let known = ["--host", "--port", "--host-key", "--keys", "--provoke", "--tmux", "--pair-code"]
        var rest = Array(arguments.dropFirst())
        var filter: String?
        while !rest.isEmpty {
            if known.contains(rest[0]), rest.count >= 2 { rest.removeFirst(2) } else { filter = rest.removeFirst() }
        }
        return TestRunner.runAndReport(RemoteMac.suites(options), filter: filter)
    }
}
