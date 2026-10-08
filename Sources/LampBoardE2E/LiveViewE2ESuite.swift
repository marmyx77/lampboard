import Darwin
import Foundation
import LampBoardCore
import TestKit

/// The live view in the real binary (D130), against a fake `claude`.
///
/// The fake lives in the fake home's `~/.local/bin`, the only place the binary
/// looks under `LAMPBOARD_HOME`. Asked to `attach`, it prints what terminal it
/// finds itself in, asks for bracketed paste as Claude Code does, and writes
/// down every byte it is sent, in raw mode so that an Enter would show as one.
/// It leaves when its terminal closes, unless a case put `survive` beside it:
/// then it ignores SIGHUP and outlives its terminal for a minute at most, so a
/// case can tell an attach LampBoard ended from one that died with its terminal.
/// Asked to start `--bg`, it prints an id the way Claude Code does.
enum LiveViewE2ESuite {

    static let job = "e2eb9a11"
    static let started = "e2ec0ffe"

    static let fake = """
    #!/bin/sh
    here="$(dirname "$0")"
    printf '%s\\n' "$*" >> "$here/calls.txt"
    case "$1" in
      attach)
        [ -f "$here/survive" ] && trap '' HUP
        printf 'ATTACHED %s TERM=%s COLORTERM=%s TMUX=%s PROGRAM=%s\\r\\n' "$2" "$TERM" "$COLORTERM" "${TMUX:-none}" "${TERM_PROGRAM:-none}"
        printf '\\033[?2004h'
        stty raw -echo 2>/dev/null
        while [ "$SECONDS" -lt 60 ]; do
          c=$(dd bs=1 count=1 2>/dev/null | od -An -c)
          if [ -z "$c" ]; then [ -f "$here/survive" ] || exit 0; sleep 1; continue; fi
          printf '%s\n' "$c" >> "$here/typed.txt"
        done
        ;;
      --bg)
        pwd > "$here/bg-folder.txt"
        printf 'backgrounded \\302\\267 \(started) \\302\\267 e2e\\n  claude attach \(started)    open in this terminal\\n'
        ;;
    esac
    """

    static func app(binaryURL: URL, port: UInt16, _ arguments: [String]) -> AppUnderTest {
        let app = AppUnderTest(binaryURL: binaryURL, port: port)
        app.extraArguments = arguments
        // What a terminal or an editor would have left in LampBoard's own environment.
        app.extraEnvironment = ["TMUX": "/tmp/tmux-501/default,1,0", "TERM_PROGRAM": "vscode"]
        app.beforeLaunch = { home in
            let bin = home.appendingPathComponent(".local/bin")
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let tool = bin.appendingPathComponent("claude")
            try? fake.write(to: tool, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            try? FileManager.default.createDirectory(at: home.appendingPathComponent("web"), withIntermediateDirectories: true)
        }
        return app
    }

    /// `GET /live`, decoded.
    static func views(_ app: AppUnderTest) -> [[String: Any]] {
        let (status, body) = app.raw(method: "GET", path: AppConfig.livePath)
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return [] }
        return object["views"] as? [[String: Any]] ?? []
    }

    /// Every attach the app reports, ended: a case leaves no process behind.
    static func endAttaches(_ app: AppUnderTest) {
        for view in views(app) { if let pid = view["pid"] as? Int, pid > 1 { kill(pid_t(pid), SIGKILL) } }
    }

    static func file(_ app: AppUnderTest, _ name: String) -> String {
        (try? String(contentsOf: app.home.appendingPathComponent(".local/bin/\(name)"), encoding: .utf8)) ?? ""
    }

    /// An app whose fake home holds a session in a fake tmux pane: the
    /// session's own process (a `sleep`) stands for the pane's shell.
    static func tmuxApp(binaryURL: URL, port: UInt16, sessionId: String, shell: Process, _ arguments: [String]) -> AppUnderTest {
        let app = app(binaryURL: binaryURL, port: port, ["--live-session", sessionId] + arguments)
        let prepare = app.beforeLaunch
        app.beforeLaunch = { home in
            prepare?(home)
            let bin = home.appendingPathComponent(".local/bin")
            let tmux = """
            #!/bin/sh
            here="$(dirname "$0")"
            printf '%s\\n' "$*" >> "$here/tmux-calls.txt"
            case "$1" in
              list-panes) cat "$here/panes.txt" ;;
              attach-session) printf 'TMUX ATTACHED %s TMUX=%s\\r\\n' "$3" "${TMUX:-none}"; exec /bin/sleep 30 ;;
            esac
            """
            try? tmux.write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("tmux").path)
            try? "\(shell.processIdentifier)\twork\t0\t0\n".write(to: bin.appendingPathComponent("panes.txt"), atomically: true, encoding: .utf8)
            let record: [String: Any] = ["pid": shell.processIdentifier, "sessionId": sessionId, "cwd": home.appendingPathComponent("web").path,
                                         "entrypoint": "cli", "kind": "interactive"]
            try? FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/sessions"), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: record)
                .write(to: home.appendingPathComponent(".claude/sessions/\(shell.processIdentifier).json"))
            try? "# Web\nline two\n".write(to: home.appendingPathComponent("web/README.md"), atomically: true, encoding: .utf8)
        }
        return app
    }

    static func sleeper() -> Process {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["60"]
        try? shell.run()
        return shell
    }

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        TestSuite("E2E · live view", [

            TestCase("a background session opens as claude attach, in a terminal that says what it is and nothing else") { t in
                let app = app(binaryURL: binaryURL, port: port, ["--live", job])
                defer { endAttaches(app); app.stop() }
                do { try app.start() } catch { t.fail("did not start: \(error)"); return }
                let shown = app.waitUntil(timeout: 15) {
                    (views(app).first?["text"] as? String ?? "").contains("ATTACHED \(job)")
                }
                t.expect(shown, "the window shows the attach: \(views(app))")
                let text = views(app).first?["text"] as? String ?? ""
                t.expect(text.contains("TERM=xterm-256color"), "TERM: \(text)")
                t.expect(text.contains("COLORTERM=truecolor"), "truecolor")
                t.expect(text.contains("TMUX=none"), "LampBoard's TMUX does not reach the session")
                t.expect(text.contains("PROGRAM=none"), "nor its TERM_PROGRAM")
                t.expectEqual(views(app).first?["running"] as? Bool, true)
                t.expect(file(app, "calls.txt").contains("attach \(job)"), "the command: \(file(app, "calls.txt"))")
            },

            TestCase("a citation arrives as a paste, never as an Enter") { t in
                let app = app(binaryURL: binaryURL, port: port, ["--live", job, "--live-paste", "@README.md\n"])
                defer { endAttaches(app); app.stop() }
                do { try app.start() } catch { t.fail("did not start: \(error)"); return }
                let typed = { file(app, "typed.txt").filter { !$0.isWhitespace } }
                let arrived = app.waitUntil(timeout: 15) { typed().contains("033[201~") }
                t.expect(arrived, "the paste reached the session: \(typed())")
                t.expect(typed().contains("033[200~@README.md\\n033[201~"), "the line break inside the marks: \(typed())")
                t.expect(typed().hasSuffix("033[201~"), "and nothing after them, no Enter: \(typed())")
            },

            TestCase("an id that is not a job's opens nothing and runs nothing") { t in
                let app = app(binaryURL: binaryURL, port: port, ["--live", "bad;id"])
                defer { endAttaches(app); app.stop() }
                do { try app.start() } catch { t.fail("did not start: \(error)"); return }
                Thread.sleep(forTimeInterval: 3)
                t.expect(views(app).isEmpty, "no window: \(views(app))")
                t.expect(file(app, "calls.txt").isEmpty, "claude never ran")
            },

            TestCase("a new session starts with claude --bg in its folder, and opens as soon as it says its id") { t in
                let app = app(binaryURL: binaryURL, port: port, [])
                app.extraArguments = ["--live-start", app.home.appendingPathComponent("web").path]
                defer { endAttaches(app); app.stop() }
                do { try app.start() } catch { t.fail("did not start: \(error)"); return }
                let opened = app.waitUntil(timeout: 15) { views(app).contains { $0["job"] as? String == started } }
                t.expect(opened, "the started session is open: \(views(app))")
                t.expect(file(app, "calls.txt").contains("--bg"), "started in the background: \(file(app, "calls.txt"))")
                t.expect(file(app, "calls.txt").contains("attach \(started)"), "then attached")
                t.expect(file(app, "bg-folder.txt").contains("/web"), "in the row's folder: \(file(app, "bg-folder.txt"))")
            },

            TestCase("a session in this Mac's tmux is found under its pane and opened with tmux attach (D132)") { t in
                let sessionId = "e2e7d0aa-0000-4000-8000-0000000074a1"
                let shell = sleeper()
                defer { shell.terminate() }
                let app = tmuxApp(binaryURL: binaryURL, port: port, sessionId: sessionId, shell: shell, [])
                defer { endAttaches(app); app.stop() }
                do { try app.start() } catch { t.fail("did not start: \(error)"); return }
                let shown = app.waitUntil(timeout: 20) {
                    views(app).contains { ($0["text"] as? String ?? "").contains("TMUX ATTACHED =work:0.0") }
                }
                t.expect(shown, "the pane's session opened with tmux attach: \(views(app)) · \(file(app, "tmux-calls.txt"))")
                t.expect(file(app, "tmux-calls.txt").contains("list-panes -a -F"), "the panes were asked for")
                t.expect(views(app).contains { ($0["text"] as? String ?? "").contains("TMUX=none") }, "attached, not nested")

                // Claude Code's look (D134): on, by default, for the session open
                // here and for no other; and only to whoever holds the token.
                let look = { (session: String, token: String??) in
                    app.raw(method: "GET", path: AppConfig.modLookPath, token: token, headers: ["X-LampBoard-Session": session])
                }
                t.expectEqual(look(sessionId, nil).body, #"{"v":1,"on":true}"#, "the session in the window")
                t.expectEqual(look("e2e7d0aa-0000-4000-8000-000000000bad", nil).body, #"{"v":1,"on":false}"#, "another session")
                t.expectEqual(look(sessionId, .some("0000")).status, 401, "a wrong token")
            },

            TestCase("the files sit beside the session: its folder, and a file in the preview (D136)") { t in
                let sessionId = "e2e7d0aa-0000-4000-8000-0000000074a2"
                let shell = sleeper()
                defer { shell.terminate() }
                let app = tmuxApp(binaryURL: binaryURL, port: port, sessionId: sessionId, shell: shell, ["--live-files", "README.md"])
                defer { endAttaches(app); app.stop() }
                do { try app.start() } catch { t.fail("did not start: \(error)"); return }
                // Its row, before the files open five seconds in: a window shows a
                // known session's folder, and a folder is known from a window on it.
                let web = app.home.appendingPathComponent("web").path
                app.writeIDELock(port: 47_211, folders: [web])
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: sessionId, cwd: web))
                let shown = app.waitUntil(timeout: 25) { views(app).contains { ($0["showing"] as? String)?.hasSuffix("/web/README.md") == true } }
                t.expect(shown, "README.md in the preview: \(views(app)) · rows \(app.sessions()?.sessions.map(\.id) ?? [])")
                t.expect(views(app).contains { ($0["folder"] as? String)?.hasSuffix("/web") == true }, "the session's folder")
            },

            TestCase("what a crash left attached is ended by the next launch, and only that") { t in
                let first = app(binaryURL: binaryURL, port: port, ["--live", job])
                let prepare = first.beforeLaunch
                first.beforeLaunch = { home in
                    prepare?(home)
                    try? "".write(to: home.appendingPathComponent(".local/bin/survive"), atomically: true, encoding: .utf8)
                }
                do { try first.start() } catch { t.fail("did not start: \(error)"); return }
                // Until the fake has said it is attached: it has set its trap by then.
                _ = first.waitUntil(timeout: 15) { (views(first).first?["text"] as? String ?? "").contains("ATTACHED") }
                let pid = pid_t(views(first).first?["pid"] as? Int ?? 0)
                guard pid > 0 else { t.fail("no attach to follow: \(views(first))"); first.stop(); return }
                first.crash()
                Thread.sleep(forTimeInterval: 2)
                t.expect(kill(pid, 0) == 0, "the attach outlived the crash, as an orphan would")
                // A stranger now holding a pid some gone LampBoard once recorded,
                // with another start time: it must be left alone.
                let stranger = Process()
                stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
                stranger.arguments = ["30"]
                try? stranger.run()
                defer { stranger.terminate() }
                let ledgers = first.home.appendingPathComponent(".lampboard/live")
                try? FileManager.default.createDirectory(at: ledgers, withIntermediateDirectories: true)
                let gone = ledgers.appendingPathComponent(LiveLedger.fileName(owner: 99_998, startedAt: 100))
                try? LiveLedger.encode([LiveLedger.Entry(pid: stranger.processIdentifier, startedAt: 12_345, job: "zzzz9999")])
                    .write(to: gone)
                let second = AppUnderTest(binaryURL: binaryURL, port: port, home: first.home)
                defer { second.stop() }
                do { try second.startReusingHome() } catch { t.fail("did not start again: \(error)"); return }
                let ended = second.waitUntil(timeout: 10) { kill(pid, 0) != 0 }
                t.expect(ended, "the next launch ended it")
                if !ended { kill(pid, SIGKILL) }
                t.expect(stranger.isRunning, "the stranger with a recorded pid but another start time is alive")
                t.expect(!FileManager.default.fileExists(atPath: gone.path), "and the gone LampBoard's ledger is cleared")
            },
        ])
    }
}
