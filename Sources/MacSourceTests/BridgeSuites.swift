#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
import LampBoardNodeLink
import TestKit

/// The PTY bridge and the named actions (§2.6, S-S, E7, E14), on a tmux server
/// of the harness's own.
@available(macOS 15.0, *)
enum MacBridgeSuite {

    static func suite(_ harness: MacHarness) -> TestSuite {
        TestSuite("The Mac's PTY bridge and named actions", [

            TestCase("A tmux session through the bridge: ❯ intact without LANG, its size from window-change, no orphan") { t in
                guard harness.tmux != nil else { return t.fail("no tmux here: the bridge was not tried") }
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                let started = harness.tmuxRun(["new-session", "-d", "-s", "alpha", "-x", "120", "-y", "40",
                                               "/bin/sh -c 'printf \"\\342\\235\\257 ready\\n\"; exec cat'"])
                t.expectEqual(started.status, 0, "the session started: \(started.output)")
                guard let connection = try? harness.actionConnection() else { return t.fail("no connection") }
                do {
                    let terminal = try Blocking.run(15) {
                        try await connection.openMacTerminal(.tmux(session: "alpha"), size: TerminalSize(columns: 100, rows: 30)!)
                    }
                    let stream = ChannelStream(terminal) { await connection.close() }
                    let screen = String(decoding: stream.drain(timeout: 5) { String(decoding: $0, as: UTF8.self).contains("❯") }, as: UTF8.self)
                    t.expect(screen.contains("❯"), "❯ reached the phone intact (tmux -u)")
                    t.expectEqual(harness.tmuxClients, 1, "one client while attached")
                    do { try Blocking.run(10) { try await terminal.resize(TerminalSize(columns: 90, rows: 25)!) } } catch { t.fail("resize: \(error)") }
                    let resized = Blocking.eventually(5) {
                        // 25 rows, one of them tmux's status line.
                        harness.tmuxRun(["display", "-p", "-t", "=alpha:", "#{window_width}x#{window_height}"]).output
                            .trimmingCharacters(in: .whitespacesAndNewlines) == "90x24"
                    }
                    t.expect(resized, "window-change resized the window")
                    stream.close()
                    t.expect(Blocking.eventually(5) { harness.tmuxClients == 0 }, "no client left when the channel closed")
                } catch {
                    t.fail("\(error)")
                }
            },

            TestCase("A session that is not in the Mac's tmux is refused") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                guard let connection = try? harness.actionConnection() else { return t.fail("no connection") }
                t.expectNotNil(MacServerSuite.refusal {
                    _ = try Blocking.run(15) { try await connection.openMacTerminal(.tmux(session: "nonesuch"), size: TerminalSize(columns: 80, rows: 24)!) }
                }, "refused")
                _ = try? Blocking.run(10) { await connection.close() }
            },

            TestCase("Background (Q7, E14): the phone's tmux client stops counting and goes") { t in
                guard harness.tmux != nil else { return t.fail("no tmux here") }
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                harness.tmuxRun(["new-session", "-d", "-s", "beta", "-x", "120", "-y", "40", "cat"])
                guard let connection = try? harness.actionConnection(),
                      let terminal = try? Blocking.run(15, { try await connection.openMacTerminal(.tmux(session: "beta"), size: TerminalSize(columns: 60, rows: 20)!) })
                else { return t.fail("no terminal") }
                t.expect(Blocking.eventually(5) { harness.tmuxClients == 1 }, "attached")
                let answer = try? Blocking.run(15) { try await connection.backgroundOnMac() }
                t.expect(answer?.output.contains(#""detached":1"#) == true, "one client detached: \(answer?.output ?? "nothing")")
                t.expect(Blocking.eventually(5) { harness.tmuxClients == 0 }, "and gone")
                _ = try? Blocking.run(10) { await terminal.close(); await connection.close() }
            },

            TestCase("10 MiB through the bridge's raw channel, byte for byte (E7)") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                var generator = SystemRandomNumberGenerator()
                let big = (0..<(10 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) }
                _ = FileManager.default.createFile(atPath: harness.home + "/big.bin", contents: Data(big))
                guard let connection = try? harness.actionConnection(),
                      let terminal = try? Blocking.run(15, { try await connection.openMacTerminal(.job("rawjob1"), size: TerminalSize(columns: 80, rows: 24)!) })
                else { return t.fail("no terminal") }
                let stream = ChannelStream(terminal) { await connection.close() }
                let got = stream.drain(timeout: 60) { $0.count >= big.count }
                t.expectEqual(got.count, big.count, "every byte arrived")
                t.expect(got == big, "and in order, unchanged")
                stream.close()
                t.expect(Blocking.eventually(5) { harness.attaches.holder(of: "rawjob1") == nil }, "the attach let go")
            },

            TestCase("Never a second claude attach: counted (D130)") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                let log = harness.home + "/attaches.log"
                try? FileManager.default.removeItem(atPath: log)
                _ = FileManager.default.createFile(atPath: harness.home + "/big.bin", contents: Data())
                // The Hub holds the job and has no terminal to share: the phone is told so.
                _ = harness.attaches.take("heldjob1", for: .hub)
                guard let connection = try? harness.actionConnection() else { return t.fail("no connection") }
                let size = TerminalSize(columns: 80, rows: 24)!
                t.expectNotNil(MacServerSuite.refusal { _ = try Blocking.run(15) { try await connection.openMacTerminal(.job("heldjob1"), size: size) } },
                               "refused while the Hub holds it")
                harness.attaches.release("heldjob1", by: .hub)
                let started = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").count ?? 0
                t.expectEqual(started, 0, "no claude attach was started")
                t.expectEqual(harness.attaches.count("heldjob1"), 1, "one attach for the job, the Hub's")
            },

            TestCase("A job open in the Hub is shared, not attached again") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                let shared = harness.hub.openInHub("hubjob1")
                _ = harness.attaches.take("hubjob1", for: .hub)
                defer { harness.attaches.release("hubjob1", by: .hub) }
                guard let connection = try? harness.actionConnection(),
                      let terminal = try? Blocking.run(15, { try await connection.openMacTerminal(.job("hubjob1"), size: TerminalSize(columns: 80, rows: 24)!) })
                else { return t.fail("no terminal") }
                let stream = ChannelStream(terminal) { await connection.close() }
                _ = try? stream.write(Array("x".utf8))
                let seen = String(decoding: stream.drain(timeout: 5) { String(decoding: $0, as: UTF8.self).contains("hub got: x") }, as: UTF8.self)
                t.expect(seen.contains("hub screen"), "the Hub's screen")
                t.expect(seen.contains("hub got: x"), "the phone's keys into the Hub's terminal")
                t.expectEqual(harness.attaches.count("hubjob1"), 1, "still one attach")
                stream.close()
                t.expect(Blocking.eventually(5) { shared.stopped }, "sharing ended with the channel")
            },

            TestCase("Named actions run as a node runs them; Bypass stays off unless the Mac allows it") { t in
                harness.terminals.on = true
                defer { harness.terminals.on = false }
                guard let connection = try? harness.actionConnection() else { return t.fail("no connection") }
                let folder = harness.home + "/projects"
                try? FileManager.default.createDirectory(atPath: folder + "/example-app", withIntermediateDirectories: true)
                let listed = try? Blocking.run(30) { try await connection.runOnMac(.browse(path: folder)) }
                t.expect(listed?.output.contains("example-app") == true, "browse: \(listed?.output.prefix(200) ?? "nothing")")
                let bypass = NodeAction.start(folder: folder + "/example-app", name: "example-app", launch: NewSession.newLaunchTag(),
                                              start: .new(sessionId: MacFixtures.sid(7), permissions: .bypass))
                let refused = try? Blocking.run(30) { try await connection.runOnMac(bypass) }
                t.expect(refused == nil || refused?.exitCode != 0, "bypass from the start refused: \(String(describing: refused))")
                _ = try? Blocking.run(10) { await connection.close() }
            },
        ])
    }
}
