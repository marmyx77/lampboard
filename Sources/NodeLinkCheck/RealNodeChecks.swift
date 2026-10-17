import Crypto
import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import TestKit

/// A real machine, reached as the phone reaches it (W3's exit on the Linux
/// machine): a test key paired with `lampd devices add --id test-…`, and a tmux
/// server of the check's own, named with `-L`. The person's own tmux server and
/// sessions are never attached to, listed or changed: every tmux command here
/// names the check's server, and the run refuses a server name that is not
/// `lb-…`. The only files it makes are `/tmp/lb-…` ones, taken away at the end.
struct RealNode {
    let endpoint: NodeEndpoint
    let hostKey: NodeHostKey
    let actionKey: ActionKey
    /// The check's own tmux server (`tmux -L <name>`).
    let server: TmuxSizeRule.Server
    let socketName: String
    let cycles: Int
    let frames: Int
    /// The time to the first frame the phone is held to: the median of `frames`
    /// attaches, in seconds (W3, «under W0's thresholds»).
    let firstFrameLimit: TimeInterval

    /// `tmux -u -L <name>`: every tmux command of the check names its own server.
    var tmuxCommand: String { "tmux -u -L \(socketName)" }
}

@available(macOS 15.0, *)
enum RealNodeChecks {

    /// A word the pane prints, so that the first frame is the pane's and not
    /// tmux clearing the screen.
    static let ready = "lb-ready"

    static func suite(_ node: RealNode) -> TestSuite {
        TestSuite("The real machine \(node.endpoint.host):\(node.endpoint.port), on tmux -L \(node.socketName)", [

            TestCase("The action key's raw terminal carries 10 MiB byte for byte") { t in
                let file = "/tmp/\(node.socketName)-raw.bin"
                let outcome = try? Blocking.run(180) { () async throws -> (String, String, Int) in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    let made = try await action.run(
                        "head -c 10485760 /dev/urandom > \(file) && sha256sum \(file) | cut -d' ' -f1")
                    let terminal = try await action.openTerminal(command: "stty raw -echo; cat \(file)",
                                                                 size: TerminalSize(columns: 80, rows: 24)!)
                    var bytes: [UInt8] = []
                    for await chunk in terminal.inbound { bytes += chunk }
                    _ = try? await action.run("rm -f \(file)")
                    let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                    return (made.output.trimmingCharacters(in: .whitespacesAndNewlines), digest, bytes.count)
                }
                print("    10 MiB: \(outcome?.2 ?? -1) bytes, sha256 there \(outcome?.0.prefix(16) ?? "-"), here \(outcome?.1.prefix(16) ?? "-")")
                t.expectEqual(outcome?.2, 10_485_760, "every byte arrived")
                t.expect(outcome != nil && outcome?.0 == outcome?.1, "the bytes arrived unchanged")
            },

            TestCase("\(node.cycles) attaches, backgrounds and closes leave no client of the phone behind") { t in
                let session = "lb-cycles"
                let outcome = try? Blocking.run(TimeInterval(30 + node.cycles * 20)) { () async throws -> [String: Int] in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    _ = try await action.run(newSession(node, session, width: 200, height: 50))
                    var found: [String: Int] = ["most at once": 0, "released": 0, "pids": 0]
                    for _ in 0..<node.cycles {
                        let terminal = try await action.attachTmux(session: session, role: .takesSize,
                                                                    size: TerminalSize(columns: 52, rows: 30)!,
                                                                    server: node.server)
                        let screen = Collector(terminal.inbound)
                        _ = await screen.wait(for: ready, within: 10)
                        guard let pid = await terminal.clientPid(within: 5) else { await terminal.close(); continue }
                        found["pids", default: 0] += 1
                        let clients = try await action.tmuxClients(server: node.server)
                        found["most at once"] = max(found["most at once"] ?? 0, clients.count)
                        // The app in the background (Q7): ignore-size and detach, then the channel goes.
                        let released = try await action.releaseTmuxSize(clients: [pid], server: node.server)
                        if released.detached[pid] != nil { found["released", default: 0] += 1 }
                        await terminal.close()
                    }
                    // tmux takes a moment to forget a client whose channel went.
                    var left = -1
                    for _ in 0..<50 {
                        left = (try? await action.tmuxClients(server: node.server).count) ?? -1
                        if left == 0 { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    found["left"] = left
                    _ = try? await action.run(killSession(node, session))
                    return found
                }
                print("    cycles: \(outcome?["pids"] ?? -1) attached, \(outcome?["released"] ?? -1) released, "
                      + "at most \(outcome?["most at once"] ?? -1) client at once, \(outcome?["left"] ?? -1) left")
                t.expectEqual(outcome?["pids"], node.cycles, "every attach gave its client's pid")
                t.expectEqual(outcome?["released"], node.cycles, "every background released its own client")
                t.expectEqual(outcome?["most at once"], 1, "never a client of a previous cycle beside the new one")
                t.expectEqual(outcome?["left"], 0, "no client left behind")
            },

            TestCase("The first frame: \(node.frames) attaches cold and \(node.frames) warm, under the limit") { t in
                let session = "lb-frames"
                let outcome = try? Blocking.run(TimeInterval(60 + node.frames * 30)) { () async throws -> ([Double], [Double]) in
                    let setup = try await act(node)
                    _ = try await setup.run(newSession(node, session, width: 80, height: 24))
                    var cold: [Double] = []
                    var warm: [Double] = []
                    for _ in 0..<node.frames {
                        // Cold: the phone back in front with no connection, as after a night.
                        let started = Date()
                        let action = try await act(node)
                        if let seconds = try await firstFrame(action, node, session, since: started) { cold.append(seconds) }
                        // Warm: the connection held (MachineLink), only the attach.
                        let again = Date()
                        if let seconds = try await firstFrame(action, node, session, since: again) { warm.append(seconds) }
                        await action.close()
                    }
                    _ = try? await setup.run(killSession(node, session))
                    await setup.close()
                    return (cold, warm)
                }
                let cold = outcome?.0 ?? [], warm = outcome?.1 ?? []
                print("    first frame, cold (connect, key, attach): \(summary(cold))")
                print("    first frame, warm (attach on the open connection): \(summary(warm))")
                t.expectEqual(cold.count, node.frames, "every cold attach drew its first frame")
                t.expectEqual(warm.count, node.frames, "every warm attach drew its first frame")
                t.expect((median(cold) ?? .infinity) < node.firstFrameLimit,
                         "cold median \(median(cold) ?? -1) s under \(node.firstFrameLimit) s")
                t.expect((median(warm) ?? .infinity) < node.firstFrameLimit,
                         "warm median \(median(warm) ?? -1) s under \(node.firstFrameLimit) s")
            },

            TestCase("Nothing of the check is left on the machine") { t in
                let left = try? Blocking.run(30) { () async throws -> String in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    _ = try? await action.run("\(node.tmuxCommand) kill-server 2>/dev/null; true")
                    return try await action.run(
                        "ls /tmp/\(node.socketName)-* 2>/dev/null; \(node.tmuxCommand) ls 2>/dev/null; true").output
                }
                t.expectEqual(left?.trimmingCharacters(in: .whitespacesAndNewlines), "", "no file and no server left")
            },
        ])
    }

    // MARK: - Helpers

    static func act(_ node: RealNode) async throws -> ActionConnection {
        try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
    }

    static func newSession(_ node: RealNode, _ session: String, width: Int, height: Int) -> String {
        "\(node.tmuxCommand) -f /dev/null new-session -d -s \(session) -x \(width) -y \(height) "
            + "'printf \"\(ready) \\342\\235\\257 \"; cat > /dev/null'"
    }

    static func killSession(_ node: RealNode, _ session: String) -> String {
        "\(node.tmuxCommand) kill-session -t =\(session) 2>/dev/null; true"
    }

    /// Seconds from `since` to the pane's text on the phone's screen; the
    /// terminal is then given back as the background would.
    static func firstFrame(_ action: ActionConnection, _ node: RealNode, _ session: String,
                           since: Date) async throws -> Double? {
        let terminal = try await action.attachTmux(session: session, role: .takesSize,
                                                    size: TerminalSize(columns: 52, rows: 30)!, server: node.server)
        let screen = Collector(terminal.inbound)
        let drawn = await screen.wait(for: ready, within: 10)
        let seconds = Date().timeIntervalSince(since)
        if let pid = await terminal.clientPid(within: 2) {
            _ = try? await action.releaseTmuxSize(clients: [pid], server: node.server)
        }
        await terminal.close()
        return drawn ? seconds : nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty, let median = median(values) else { return "none" }
        let sorted = values.sorted()
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        func ms(_ v: Double) -> String { "\(Int((v * 1000).rounded())) ms" }
        return "n=\(values.count), median \(ms(median)), p90 \(ms(p90)), min \(ms(sorted.first!)), max \(ms(sorted.last!))"
    }
}
