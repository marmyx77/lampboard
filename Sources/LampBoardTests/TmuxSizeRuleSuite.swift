import Foundation
import LampBoardCore
import TestKit

/// Q7 of the mobile plan as code (D176): the exact tmux commands for "the phone
/// takes the size while it is in front", "in the background the phone's own
/// client lets go", and "the iPad watches without resizing". The scripts are run
/// here under `/bin/sh` against a stand-in `tmux` that prints what it was asked,
/// so the quoting is proved, not read. The same rule against a real tmux 3.4,
/// three clients and a phone over ssh, is in `Scripts/test-nodelink.sh`.
enum TmuxSizeRuleSuite {

    /// A `tmux` that prints its pid and its arguments, one in brackets each, and
    /// answers `list-clients` with two made-up clients.
    static let fakeTmux = """
    #!/bin/sh
    case "$*" in
      *list-clients*) printf '111 /dev/pts/1\\n222 /dev/pts/2\\n'; exit 0 ;;
    esac
    printf 'tmux pid=%s' "$$"
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\\n'
    """

    /// Runs `command` under `/bin/sh` with the stand-in first on the PATH.
    static func run(_ command: String) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lbtest-tmux-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmux = dir.appendingPathComponent("tmux")
            try fakeTmux.write(to: tmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        } catch {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "\(dir.path):/usr/bin:/bin", "HOME": dir.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func every(_ server: TmuxSizeRule.Server = .default) -> [String] {
        [
            TmuxSizeRule.attach(session: "api", role: .takesSize, server: server) ?? "",
            TmuxSizeRule.attach(session: "api", role: .watches, server: server) ?? "",
            TmuxSizeRule.background(clients: [111, 222], server: server),
            TmuxSizeRule.takeSize(client: 111, server: server),
            TmuxSizeRule.clients(server: server),
        ]
    }

    static let suite = TestSuite("tmux size rule (Q7)", [

        TestCase("The phone's attach prints its own pid, then becomes tmux: the pid is the client's") { t in
            guard let command = TmuxSizeRule.attach(session: "api", role: .takesSize),
                  let output = run(command) else { t.fail("the attach did not run"); return }
            var mark = TmuxClientMark()
            let rest = String(decoding: mark.pass(Array(output.utf8)), as: UTF8.self)
            t.expectNotNil(mark.pid, "the mark carried a pid")
            t.expectEqual(rest, "tmux pid=\(mark.pid ?? -1) [-u] [attach-session] [-t] [=api]\n",
                          "exec kept the pid, and the session is named exactly")
        },

        TestCase("The iPad that watches attaches with ignore-size, so its keys never resize") { t in
            guard let command = TmuxSizeRule.attach(session: "api", role: .watches), let output = run(command) else {
                t.fail("the attach did not run"); return
            }
            var mark = TmuxClientMark()
            let rest = String(decoding: mark.pass(Array(output.utf8)), as: UTF8.self)
            t.expect(rest.hasSuffix("[-u] [attach-session] [-f] [ignore-size] [-t] [=api]\n"), "watching: \(rest)")
        },

        TestCase("A session name with a quote stays one word on the other machine") { t in
            guard let command = TmuxSizeRule.attach(session: "it's a test", role: .takesSize), let output = run(command) else {
                t.fail("the attach did not run"); return
            }
            t.expect(output.hasSuffix("[-t] [=it's a test]\n"), "one argument, quote and spaces kept: \(output)")
        },

        TestCase("A name tmux would not take back is refused before anything runs") { t in
            for name in ["", "a:b", "a.b", "tab\there", String(repeating: "x", count: 201)] {
                t.expectNil(TmuxSizeRule.attach(session: name, role: .takesSize), "refused: \(name.prefix(12))")
            }
        },

        TestCase("In the background the phone's own client lets go of the size and detaches, found by its pid") { t in
            guard let output = run(TmuxSizeRule.background(clients: [222, 333])) else { t.fail("did not run"); return }
            let lines = output.split(separator: "\n").map(String.init)
            t.expect(lines.contains { $0.hasSuffix("[-u] [refresh-client] [-t] [/dev/pts/2] [-f] [ignore-size] [;] [detach-client] [-t] [/dev/pts/2]") },
                     "ignore-size and detach, in one call, on that client only: \(output)")
            t.expect(!output.contains("/dev/pts/1"), "the other client is left alone")
            let outcome = TmuxSizeRule.parseBackground(output)
            t.expectEqual(outcome.detached, [222: "/dev/pts/2"], "the client let go")
            t.expectEqual(outcome.absent, [333], "a pid with no client is said, not guessed")
        },

        TestCase("With no client to let go, the script says so and does nothing") { t in
            let output = run(TmuxSizeRule.background(clients: []))
            t.expectEqual(output, "none\n", "nothing asked, nothing done")
            t.expectEqual(TmuxSizeRule.parseBackground(output ?? ""), TmuxSizeRule.Background(detached: [:], absent: []), "empty")
        },

        TestCase("The iPad that wants the size back drops ignore-size; a key from it then takes it") { t in
            guard let output = run(TmuxSizeRule.takeSize(client: 111)) else { t.fail("did not run"); return }
            t.expect(output.contains("[refresh-client] [-t] [/dev/pts/1] [-f] [!ignore-size]"), "only that client: \(output)")
        },

        TestCase("No command ever resizes the window or changes window-size") { t in
            for command in every() + every(TmuxSizeRule.Server.named("lbtest") ?? .default) {
                t.expect(!command.contains("resize-window"), "resize-window sets the window to manual (S-D)")
                t.expect(!command.contains("window-size"), "the person's window-size is not touched")
                t.expect(command.contains("tmux -u"), "every tmux call is told the terminal is UTF-8")
            }
        },

        TestCase("A named server is used by every call; a name that is not a word is refused") { t in
            guard let server = TmuxSizeRule.Server.named("lbtest-1") else { t.fail("refused a good name"); return }
            for command in every(server) {
                t.expect(command.contains("-L '\\''lbtest-1'\\''") || command.contains("-L 'lbtest-1'"), "named: \(command.prefix(80))")
            }
            t.expectNil(TmuxSizeRule.Server.named("a b"), "a space")
            t.expectNil(TmuxSizeRule.Server.named("-x"), "an option")
            t.expectNil(TmuxSizeRule.Server.named(""), "empty")
        },

        TestCase("The clients are read back with their size and flags; a broken line is skipped") { t in
            let output = "123\t/dev/pts/3\t45\t30\tattached,focused,UTF-8\n456\t/dev/pts/4\t120\t40\tattached,ignore-size,UTF-8\ngarbage\n"
            let clients = TmuxSizeRule.parseClients(output)
            t.expectEqual(clients.count, 2, "two clients")
            t.expectEqual(clients.first, TmuxClient(pid: 123, name: "/dev/pts/3", width: 45, height: 30, ignoresSize: false), "the phone")
            t.expectEqual(clients.last?.ignoresSize, true, "the iPad watches")
        },

        TestCase("The pid mark is found across chunks, after other output, and taken out of the bytes") { t in
            let mark = Array("\u{1B}]1337;LampBoardClient=4242\u{07}".utf8)
            let bytes = Array("motd\r\n".utf8) + mark + Array("❯ ready".utf8)
            var scanner = TmuxClientMark()
            var out: [UInt8] = []
            for byte in bytes { out += scanner.pass([byte]) }
            out += scanner.finish()
            t.expectEqual(scanner.pid, 4242, "the pid")
            t.expectEqual(String(decoding: out, as: UTF8.self), "motd\r\n❯ ready", "everything else, in order, once")
        },

        TestCase("Without a mark, the bytes pass through untouched once the scanner gives up") { t in
            var scanner = TmuxClientMark(limit: 16)
            let first = scanner.pass(Array("\u{1B}]1337;Lamp".utf8))
            let rest = scanner.pass(Array("Other=1\u{07} plain text after".utf8))
            let all = String(decoding: first + rest + scanner.finish(), as: UTF8.self)
            t.expectNil(scanner.pid, "no pid invented")
            t.expectEqual(all, "\u{1B}]1337;LampOther=1\u{07} plain text after", "nothing lost, nothing added")
        },
    ])
}
