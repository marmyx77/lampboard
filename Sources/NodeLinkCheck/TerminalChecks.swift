import Crypto
import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import TestKit

/// The terminal, the size rule of Q7 and the lights read over ssh, against a
/// real OpenSSH and a real tmux 3.4 on the node (D176). Everything it makes on
/// the node is named `lbcheck-*` and taken away at the end of its case.
@available(macOS 15.0, *)
enum TerminalChecks {

    static func suite(_ node: CheckedNode) -> TestSuite {
        TestSuite("Terminal and lights over ssh: \(node.tmuxEndpoint.host)", [

            TestCase("The node is the Linux machine's versions: tmux 3.4, OpenSSH 9.6") { t in
                let versions = try? Blocking.run(30) { () async throws -> String in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    return try await action.run("tmux -V; ssh -V 2>&1").output
                }
                t.expect(versions?.contains("tmux 3.4") == true, "the size rule is proved on tmux 3.4: \(versions ?? "no answer")")
                t.expect(versions?.contains("OpenSSH_9.6") == true, "behind OpenSSH 9.6")
            },

            TestCase("The raw channel carries 10 MiB byte for byte, in pieces of at most 32 KiB") { t in
                let outcome = try? Blocking.run(120) { () async throws -> (String, String, Int, Int, Int?) in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    let made = try await action.run(
                        "head -c 10485760 /dev/urandom > /tmp/lbcheck-raw.bin && sha256sum /tmp/lbcheck-raw.bin | cut -d' ' -f1")
                    let terminal = try await action.openTerminal(command: "stty raw -echo; cat /tmp/lbcheck-raw.bin",
                                                                 size: TerminalSize(columns: 80, rows: 24)!)
                    var bytes: [UInt8] = []
                    var largest = 0
                    for await chunk in terminal.inbound {
                        bytes += chunk
                        largest = max(largest, chunk.count)
                    }
                    _ = try? await action.run("rm -f /tmp/lbcheck-raw.bin")
                    let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                    return (made.output.trimmingCharacters(in: .whitespacesAndNewlines), digest, bytes.count, largest,
                            terminal.exitStatus)
                }
                t.expectEqual(outcome?.2, 10_485_760, "every byte arrived")
                t.expect(outcome != nil && outcome?.0 == outcome?.1,
                         "the raw channel did not carry the bytes unchanged: \(String(describing: outcome?.0.prefix(12))) against \(String(describing: outcome?.1.prefix(12)))")
                t.expect((outcome?.3 ?? .max) <= V1Frame.writePiece, "no piece above 32 KiB: \(outcome?.3 ?? -1)")
                t.expectEqual(outcome?.4, 0, "the command ended well, and the end was a normal one")
            },

            TestCase("A write far larger than the channel's window reaches the machine whole") { t in
                let outcome = try? Blocking.run(120) { () async throws -> (String, String) in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    var bytes = [UInt8](repeating: 0, count: 1 << 20)
                    for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 7) }
                    // Written only once the line discipline is raw: before, the
                    // terminal would turn carriage returns and echo them back.
                    let terminal = try await action.openTerminal(
                        command: "stty raw -echo; printf R; head -c 1048576 > /tmp/lbcheck-in.bin", size: TerminalSize(columns: 80, rows: 24)!)
                    let screen = Collector(terminal.inbound)
                    _ = await screen.wait(for: "R", within: 10)
                    try await terminal.write(bytes)
                    _ = await screen.ended(within: 60)
                    let there = try await action.run("sha256sum /tmp/lbcheck-in.bin | cut -d' ' -f1; rm -f /tmp/lbcheck-in.bin")
                    let here = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                    return (there.output.trimmingCharacters(in: .whitespacesAndNewlines), here)
                }
                t.expect(outcome != nil && outcome?.0 == outcome?.1, "1 MiB written in 32 KiB pieces arrived unchanged")
            },

            TestCase("The read key cannot open a terminal: the machine refuses the PTY") { t in
                let outcome = Result { try Blocking.run(30) { () async throws -> String in
                    let connection = try await NodeLink.read(node.tmuxEndpoint, trust: .pinned(node.tmuxHostKey), key: node.readKey)
                    defer { Task { await connection.close() } }
                    let terminal = try await connection.openTerminalAnyway(command: "id", size: TerminalSize(columns: 80, rows: 24)!)
                    await terminal.close()
                    return "opened"
                } }
                if case .failure(let error as NodeLinkError) = outcome, case .refused = error {
                    t.expect(true, "refused")
                } else {
                    t.expect(false, "the read key's terminal was not refused: \(outcome)")
                }
            },

            TestCase("A terminal the machine ends is a normal end, with the command's exit status") { t in
                let outcome = try? Blocking.run(30) { () async throws -> (Int?, Bool) in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    let terminal = try await action.openTerminal(command: "exit 3", size: TerminalSize(columns: 80, rows: 24)!)
                    for await _ in terminal.inbound {}
                    var refused = false
                    do { try await terminal.write([0x0A]) } catch { refused = (error as? NodeLinkError) == .closed }
                    await terminal.close()
                    await terminal.close()
                    return (terminal.exitStatus, refused)
                }
                t.expectEqual(outcome?.0, 3, "exit status 3")
                t.expectEqual(outcome?.1, true, "a write after the end is refused as closed")
            },

            TestCase("Through tmux: the screen arrives in UTF-8, a key reaches the pane, window-change resizes") { t in
                let session = "lbcheck-term"
                let outcome = try? Blocking.run(60) { () async throws -> [String: String] in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    _ = try await action.run("tmux -u new-session -d -s \(session) -x 80 -y 24 'printf \"ready \\342\\235\\257 \"; cat'")
                    var found: [String: String] = [:]
                    let terminal = try await action.attachTmux(session: session, role: .takesSize, size: TerminalSize(columns: 100, rows: 30)!)
                    let screen = Collector(terminal.inbound)
                    found["prompt"] = String(await screen.wait(for: "ready ❯", within: 10))
                    let pid = await terminal.clientPid(within: 5)
                    let clients = try await action.tmuxClients()
                    found["pid"] = String(pid.map { p in clients.contains { $0.pid == p && $0.width == 100 } } ?? false)
                    found["mark"] = String(!screen.text.contains("LampBoardClient"))
                    try await terminal.write(Array("hello".utf8))
                    found["typed"] = String(await eventually(5) {
                        ((try? await action.run("tmux -u capture-pane -p -t '=\(session):'"))?.output ?? "").contains("hello")
                    })
                    try await terminal.resize(TerminalSize(columns: 60, rows: 20)!)
                    found["resized"] = String(await eventually(5) { await width(action, session) == 60 })
                    await terminal.close()
                    found["left"] = String(await eventually(5) {
                        ((try? await action.tmuxClients()) ?? [TmuxClient(pid: 0, name: "", width: 0, height: 0, ignoresSize: false)]).isEmpty
                    })
                    _ = try? await action.run("tmux -u kill-session -t =\(session)")
                    return found
                }
                t.expectEqual(outcome?["prompt"], "true", "the pane's text, ❯ intact (tmux -u)")
                t.expectEqual(outcome?["pid"], "true", "the mark gave this terminal's own client, at its size")
                t.expectEqual(outcome?["mark"], "true", "and was taken out of the screen")
                t.expectEqual(outcome?["typed"], "true", "a key reached the pane")
                t.expectEqual(outcome?["resized"], "true", "window-change resized the window")
                t.expectEqual(outcome?["left"], "true", "closing left no client behind")
            },

            TestCase("Q7 on tmux 3.4: the phone takes the size, and in the background the Mac takes it back") { t in
                let session = "lbcheck-size"
                let outcome = try? Blocking.run(120) { () async throws -> [String: Int] in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    _ = try await action.run("tmux -u new-session -d -s \(session) -x 200 -y 50 'cat > /dev/null'")
                    var widths: [String: Int] = [:]
                    let plain = "tmux -u attach-session -t =\(session)"
                    let mac = try await action.openTerminal(command: plain, size: TerminalSize(columns: 200, rows: 50)!)
                    let macScreen = Collector(mac.inbound)
                    _ = macScreen
                    try await key(mac)
                    widths["mac"] = await settle(action, session, 200)
                    let ipad = try await action.openTerminal(command: plain, size: TerminalSize(columns: 120, rows: 40)!)
                    let ipadScreen = Collector(ipad.inbound)
                    _ = ipadScreen
                    try await key(ipad)
                    widths["ipad"] = await settle(action, session, 120)
                    try await key(mac)
                    widths["mac again"] = await settle(action, session, 200)

                    let phone = try await action.attachTmux(session: session, role: .takesSize, size: TerminalSize(columns: 45, rows: 30)!)
                    let phoneScreen = Collector(phone.inbound)
                    _ = phoneScreen
                    widths["phone attached"] = await settle(action, session, 45)
                    let pid = await phone.clientPid(within: 5) ?? 0
                    widths["phone pid"] = pid
                    try await phone.write(Array("x".utf8))
                    widths["phone writes"] = await settle(action, session, 45)

                    // B2: ignore-size alone, with three clients, leaves the Mac narrow.
                    _ = try await action.run(
                        "tmux -u refresh-client -t \"$(tmux -u list-clients -F '#{client_pid} #{client_name}' | awk '$1==\(pid){print $2}')\" -f ignore-size")
                    widths["ignore-size alone"] = await settle(action, session, 200, within: 2)
                    _ = try await action.run(
                        "tmux -u refresh-client -t \"$(tmux -u list-clients -F '#{client_pid} #{client_name}' | awk '$1==\(pid){print $2}')\" -f '!ignore-size'")

                    let released = try await action.releaseTmuxSize(clients: [pid])
                    widths["released"] = released.detached[pid] == nil ? 0 : 1
                    widths["background"] = await settle(action, session, 200)
                    widths["phone clients left"] = (try await action.tmuxClients()).filter { $0.pid == pid }.count
                    await phone.close()

                    // The iPad watches: its keys do not resize; asked, it takes the size.
                    await ipad.close()
                    let watcher = try await action.attachTmux(session: session, role: .watches, size: TerminalSize(columns: 120, rows: 40)!)
                    let watcherScreen = Collector(watcher.inbound)
                    _ = watcherScreen
                    let watcherPid = await watcher.clientPid(within: 5) ?? 0
                    try await key(watcher)
                    widths["watcher writes"] = await settle(action, session, 200, within: 2)
                    widths["taken"] = (try await action.takeTmuxSize(client: watcherPid)) ? 1 : 0
                    try await key(watcher)
                    widths["watcher takes"] = await settle(action, session, 120)

                    await watcher.close()
                    await mac.close()
                    _ = try? await action.run("tmux -u kill-session -t =\(session)")
                    return widths
                }
                t.expectEqual(outcome?["mac"], 200, "the Mac alone")
                t.expectEqual(outcome?["ipad"], 120, "the iPad used")
                t.expectEqual(outcome?["mac again"], 200, "the Mac used last")
                t.expectEqual(outcome?["phone attached"], 45, "a new client wins at once, without a key (B4)")
                t.expect((outcome?["phone pid"] ?? 0) > 0, "the phone's client is known by its pid")
                t.expectEqual(outcome?["phone writes"], 45, "and every key confirms it")
                t.expectEqual(outcome?["ignore-size alone"], 45, "ignore-size alone leaves the Mac narrow with three clients (B2)")
                t.expectEqual(outcome?["released"], 1, "the rule found the phone's client and let it go")
                t.expect(outcome?["background"] == 200,
                         "the Mac stayed narrow after the phone went to the background: \(outcome?["background"] ?? -1)")
                t.expectEqual(outcome?["phone clients left"], 0, "no phone client left behind")
                t.expectEqual(outcome?["watcher writes"], 200, "the watching iPad's keys do not resize (D1)")
                t.expectEqual(outcome?["taken"], 1, "asked, it drops ignore-size")
                t.expectEqual(outcome?["watcher takes"], 120, "and a key then takes the size (A6)")
            },

            TestCase("The lights of a machine without v1, read over ssh: rows, tmux, changes, and nothing written") { t in
                let outcome = try? Blocking.run(120) { () async throws -> [String: String] in
                    let action = try await act(node)
                    defer { Task { await action.close() } }
                    _ = try? await action.run(Self.removeFakeSessions)
                    let setup = try await action.run(Self.fakeSessions)
                    var found: [String: String] = ["setup": setup.output.trimmingCharacters(in: .whitespacesAndNewlines)]
                    let source = V1ProbeSource(identity: V1SourceIdentity(kind: .node, name: "check-node"), startedAt: Date(),
                                               journal: "check")
                    let probe = ProbeLink(source: source, interval: 3600) { command in try await action.run(command) }
                    _ = try await action.run("touch /tmp/lbcheck-mark; sleep 1.1")
                    found["answered"] = String(await probe.look())
                    found["written"] = try await action.run(
                        "find /home/\(node.endpoint.user) -newer /tmp/lbcheck-mark | head -5").output
                    let rows = source.snapshot(at: Date()).rows ?? []
                    let busy = rows.first { $0.id == "44444444-4444-4444-8444-444444444444" }
                    let idle = rows.first { $0.id == "55555555-5555-4555-8555-555555555555" }
                    found["count"] = String([busy, idle].compactMap { $0 }.count)
                    found["busy"] = busy?.session.status ?? "none"
                    found["terminal"] = busy?.extras.terminal ?? "none"
                    found["idle"] = idle?.session.status ?? "none"
                    found["basis"] = busy?.extras.stateBasis?.rawValue ?? "none"
                    found["tmux"] = String(source.tmuxSessions?.contains { $0.name == "lbcheck-claude" } ?? false)
                    let seq = source.status(at: Date()).seq
                    _ = try await action.run("sed -i 's/\"busy\"/\"idle\"/' ~/.claude/sessions/$(cat /tmp/lbcheck-busy.pid).json")
                    await probe.look()
                    found["after change"] = source.snapshot(at: Date()).rows?.first { $0.id == busy?.id }?.session.status ?? "none"
                    found["events"] = String(source.status(at: Date()).seq - seq)
                    _ = try await action.run("kill $(cat /tmp/lbcheck-idle.pid)")
                    await probe.look()
                    let after = source.snapshot(at: Date()).rows ?? []
                    found["after end"] = String(after.contains { $0.id == busy?.id } && !after.contains { $0.id == idle?.id })
                    _ = try? await action.run(Self.removeFakeSessions)
                    return found
                }
                t.expectEqual(outcome?["setup"], "ready", "two sessions made on the node")
                t.expectEqual(outcome?["answered"], "true", "the machine answered")
                t.expectEqual(outcome?["written"], "", "the look wrote nothing in the home")
                t.expectEqual(outcome?["count"], "2", "a row for each of the two conversations")
                t.expectEqual(outcome?["busy"], "working", "busy in its file is working")
                t.expectEqual(outcome?["terminal"], "tmux:lbcheck-claude", "where tmux holds it, to open a terminal")
                t.expectEqual(outcome?["idle"], "idle", "the other idle")
                t.expectEqual(outcome?["basis"], "sessionFile", "each row says it was read, not heard")
                t.expectEqual(outcome?["tmux"], "true", "tmux's sessions listed")
                t.expectEqual(outcome?["after change"], "idle", "a change in the file is a change of the row")
                t.expectEqual(outcome?["events"], "1", "one event for it")
                t.expectEqual(outcome?["after end"], "true", "an ended session's row goes, the other stays")
            },
        ])
    }

    /// Two made-up Claude Code sessions in the node's home: one busy in tmux,
    /// one idle outside it, each with its file and a transcript.
    static let fakeSessions = #"""
    set -e
    tmux -u new-session -d -s lbcheck-claude 'sleep 100000'
    busy=$(tmux -u list-panes -t =lbcheck-claude -F '#{pane_pid}')
    sleep 100000 < /dev/null > /dev/null 2>&1 &
    idle=$!
    echo "$busy" > /tmp/lbcheck-busy.pid; echo "$idle" > /tmp/lbcheck-idle.pid
    mkdir -p ~/.claude/sessions ~/.claude/projects/-home-check-api ~/.claude/projects/-home-check-web
    printf '{"pid":%s,"sessionId":"44444444-4444-4444-8444-444444444444","cwd":"/home/check/api","entrypoint":"cli","kind":"interactive","status":"busy"}' "$busy" > ~/.claude/sessions/$busy.json
    printf '{"pid":%s,"sessionId":"55555555-5555-4555-8555-555555555555","cwd":"/home/check/web","entrypoint":"cli","kind":"interactive","status":"idle"}' "$idle" > ~/.claude/sessions/$idle.json
    tail='{"type":"assistant","timestamp":"2025-10-09T08:00:00Z","message":{"model":"claude-opus-4-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000}}}'
    echo "$tail" > ~/.claude/projects/-home-check-api/44444444-4444-4444-8444-444444444444.jsonl
    echo "$tail" > ~/.claude/projects/-home-check-web/55555555-5555-4555-8555-555555555555.jsonl
    echo ready
    """#

    /// Takes away exactly what `fakeSessions` made, and nothing else of the home.
    static let removeFakeSessions = #"""
    tmux -u kill-session -t =lbcheck-claude 2>/dev/null
    for f in /tmp/lbcheck-busy.pid /tmp/lbcheck-idle.pid; do
        [ -f "$f" ] && { kill "$(cat "$f")" 2>/dev/null; rm -f ~/.claude/sessions/"$(cat "$f")".json "$f"; }
    done
    rm -rf ~/.claude/projects/-home-check-api ~/.claude/projects/-home-check-web /tmp/lbcheck-mark
    true
    """#

    // MARK: - Helpers

    /// The tmux node: the Linux machine's OpenSSH, tmux and Python.
    static func act(_ node: CheckedNode) async throws -> ActionConnection {
        try await NodeLink.act(node.tmuxEndpoint, trust: .pinned(node.tmuxHostKey), key: node.actionKey)
    }

    /// A key, for tmux: activity that makes a client `latest`.
    static func key(_ channel: NodeByteChannel) async throws {
        try await channel.write(Array("x".utf8))
    }

    static func width(_ action: ActionConnection, _ session: String) async -> Int? {
        let output = try? await action.run("tmux -u display-message -p -t '=\(session):' '#{window_width}'").output
        return output.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The window's width once it is `expected`, or whatever it is after `within` seconds.
    static func settle(_ action: ActionConnection, _ session: String, _ expected: Int, within seconds: TimeInterval = 5) async -> Int {
        let end = Date().addingTimeInterval(seconds)
        var last = -1
        while Date() < end {
            last = await width(action, session) ?? -1
            if last == expected { return last }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return last
    }

    static func eventually(_ seconds: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

/// Reads a terminal's bytes as they come, so that its window keeps moving.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    init(_ inbound: AsyncStream<[UInt8]>) {
        Task.detached { [weak self] in
            for await chunk in inbound { self?.append(chunk) }
            self?.finish()
        }
    }

    private func finish() {
        lock.lock()
        over = true
        lock.unlock()
    }

    private var over = false

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }

    /// Whether the stream finished within `seconds`.
    func ended(within seconds: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if lock.withLock({ over }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { over }
    }

    func wait(for needle: String, within seconds: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if text.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return text.contains(needle)
    }

    private func append(_ chunk: [UInt8]) {
        lock.lock()
        bytes += chunk
        lock.unlock()
    }
}
