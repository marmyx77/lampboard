import LampBoardCore
import Foundation
import TestKit

/// The installation and the **real hook script**, run the way Claude Code runs it.
///
/// This is the test run that covers the most ground: it generates the script,
/// actually makes it run with the payload on stdin and the environment variable
/// in the right place, and checks that the row appears in the column. In between
/// sit bash, `curl`, the socket, the HTTP parser, the decoder and the reducer —
/// the complete chain, the one a domain test never crosses.
enum InstallationSuite {

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · installation and hook script", [

            TestCase("install-hooks writes settings.json and the script") { a in
                let result = app.runCommand([
                    "install-hooks", "--port", String(app.port),
                ])
                a.expectEqual(result.status, 0, "exit code — output: \(result.output)")

                let script = app.home.appendingPathComponent(".lampboard/hook.sh")
                a.expect(
                    FileManager.default.fileExists(atPath: script.path),
                    "script not written at \(script.path)"
                )
            },

            TestCase("the hook script is executable") { a in
                let script = app.home.appendingPathComponent(".lampboard/hook.sh")
                let attributes = try? FileManager.default.attributesOfItem(atPath: script.path)
                guard let permissions = attributes?[.posixPermissions] as? NSNumber else {
                    return a.fail("permissions unreadable")
                }
                a.expectEqual(permissions.int16Value & 0o111, 0o111, "execute bits")
            },

            TestCase("every expected event turns out to be registered") { a in
                guard let hooks = app.claudeSettings()["hooks"] as? [String: Any] else {
                    return a.fail("no hooks key in settings.json")
                }
                for event in HookConfigMerger.defaultEvents {
                    a.expect(hooks[event] != nil, "event not registered: \(event)")
                }
            },

            // The seam the domain tests cannot reach. `HookConfigMerger` is proved
            // to build both forms, but nothing there notices if the installer stops
            // handing it an endpoint: drop that one argument and every merger case
            // stays green while the shipped binary quietly goes back to spawning a
            // shell per tool call.
            TestCase("the installed file really holds the native form") { a in
                guard let hooks = app.claudeSettings()["hooks"] as? [String: Any] else {
                    return a.fail("no hooks key in settings.json")
                }

                func firstHook(_ event: String) -> [String: Any]? {
                    let groups = hooks[event] as? [[String: Any]] ?? []
                    return (groups.first?["hooks"] as? [[String: Any]])?.first
                }

                // `PostToolUse` and not `Stop`: `Stop` keeps its script, because it
                // is the only per-turn event that can carry the git identity, and a
                // native hook can only send headers already written in the file.
                guard let heartbeat = firstHook("PostToolUse") else {
                    return a.fail("no hook on PostToolUse")
                }
                a.expectEqual(heartbeat["type"] as? String, "http", "the heartbeat posts natively")
                a.expect(
                    HookConfigMerger.isOurEndpoint(heartbeat["url"] as? String ?? ""),
                    "url: \(String(describing: heartbeat["url"]))"
                )
                let headers = heartbeat["headers"] as? [String: Any] ?? [:]
                a.expectNotNil(headers[AccessToken.headerName], "the token header")

                // The two measured exceptions, checked here because getting either
                // wrong is invisible until somebody's session says nothing or their
                // terminal fills with connection errors.
                for event in HookConfigMerger.commandOnlyEvents.sorted() {
                    a.expectEqual(firstHook(event)?["type"] as? String, "command", event)
                }
            },

            // The generated script is shell that Claude Code will run thousands of
            // times a day. A syntax error in it fails silently — the hook exits
            // non-zero, the panel simply never hears anything — so the shell's own
            // parser is asked before shipping it.
            TestCase("the generated script is shell bash will accept") { a in
                let script = app.home.appendingPathComponent(".lampboard/hook.sh")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-n", script.path]
                let errors = Pipe()
                process.standardError = errors
                guard (try? process.run()) != nil else { return a.fail("bash did not run") }
                let complaint = String(
                    decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
                )
                process.waitUntilExit()
                a.expectEqual(process.terminationStatus, 0, "bash -n said: \(complaint)")
            },

            // The whole chain for the git identity, through the real script: a
            // session start in a real repository has to reach the column carrying
            // the repository and the branch. The app itself never looks — it must
            // not read under somebody's working directory — so if the script does
            // not send it, nothing else will.
            TestCase("a session start in a repository carries its branch to the row") { a in
                // The workspace the other cases use, made into a repository: a
                // folder no editor claims earns no row at all (D25), so a fresh
                // directory here would fail for a reason that has nothing to do
                // with git.
                let repo = URL(fileURLWithPath: LifecycleSuite.workspace)
                try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
                for arguments in [["init", "--initial-branch=trunk"], ["commit", "--allow-empty", "-m", "x"]] {
                    let git = Process()
                    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    git.arguments = ["-C", repo.path] + arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["GIT_AUTHOR_NAME"] = "t"
                    environment["GIT_AUTHOR_EMAIL"] = "t@t"
                    environment["GIT_COMMITTER_NAME"] = "t"
                    environment["GIT_COMMITTER_EMAIL"] = "t@t"
                    git.environment = environment
                    git.standardOutput = FileHandle.nullDevice
                    git.standardError = FileHandle.nullDevice
                    try? git.run()
                    git.waitUntilExit()
                }

                let id = "e2e-git-identity"
                let rc = app.runHookScript(payload: [
                    "session_id": id,
                    "hook_event_name": "SessionStart",
                    "cwd": repo.path,
                ])
                a.expectEqual(rc, 0, "the script did not run")
                _ = app.runHookScript(payload: [
                    "session_id": id, "hook_event_name": "UserPromptSubmit", "cwd": repo.path,
                ])
                // The identity rides the end of the turn as well as the start, and
                // for a brand new session that is the only one that lands: its start
                // carries no conversation, so it earns no row (D44) and is dropped.
                _ = app.runHookScript(payload: [
                    "session_id": id, "hook_event_name": "Stop", "cwd": repo.path,
                    "last_assistant_message": "done",
                ])

                // The row arrives over a socket, so it is waited for like every
                // other one here rather than read the instant the script returns.
                a.expect(app.waitUntil { app.session(id: id) != nil }, "no row for the session")
                guard let session = app.session(id: id) else { return }
                a.expectEqual(session.git?.repo, repo.lastPathComponent, "repository")
                a.expectEqual(session.git?.branch, "trunk", "branch")
                a.expect(session.git?.isWorktree != true, "an ordinary checkout is not a worktree")
            },

            // The seam that matters for requiring a token on `POST /signal` later.
            // Both halves of an installation have to carry it: the header on a
            // native hook, and the script — which runs `SessionStart`, `SessionEnd`
            // and `Stop`, and `Stop` is what turns a row green. Read-only: it
            // judges what `install-hooks` wrote at the top of this suite, and
            // reinstalling here would change what every later case runs against.
            //
            // Seen failing on 20 September 2026 with the installer handing the
            // script no token, which is the one defect it exists to catch.
            TestCase("both halves of the installation carry the token") { a in
                guard let token = app.tokenValue else { return a.fail("no token read") }

                guard let hooks = app.claudeSettings()["hooks"] as? [String: Any] else {
                    return a.fail("no hooks key in settings.json")
                }
                a.expect(
                    !HookConfigMerger.lacksToken(
                        in: ["hooks": hooks],
                        scriptPath: app.home.appendingPathComponent(".lampboard/hook.sh").path,
                        token: token
                    ),
                    "a native hook does not carry the current token"
                )

                let script = app.home.appendingPathComponent(".lampboard/hook.sh")
                let text = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
                a.expect(text.contains(token), "the script does not carry the token")
                a.expect(
                    text.contains(AccessToken.headerName),
                    "the script does not name the header"
                )
            },

            TestCase("the two subagent events are among the registered ones") { a in
                guard let hooks = app.claudeSettings()["hooks"] as? [String: Any] else {
                    return a.fail("no hooks key")
                }
                // Without these two the counter never receives anything and the
                // feature only exists in the tests.
                a.expect(hooks["SubagentStart"] != nil, "SubagentStart missing")
                a.expect(hooks["SubagentStop"] != nil, "SubagentStop missing")
            },

            TestCase("the hook script delivers the signal to the panel") { a in
                let id = "e2e-hook-script"
                let status = app.runHookScript(payload: HookPayloads.userPromptSubmit(
                    sessionId: id, cwd: LifecycleSuite.workspace
                ))
                a.expectEqual(status, 0, "script exit")
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("the script carries the entrypoint in the header") { a in
                let id = "e2e-script-entrypoint"
                // A non-interactive session has to stay out: if the header never
                // arrived, the filter would have nothing to work on and the row
                // would show up anyway.
                app.runHookScript(
                    payload: HookPayloads.userPromptSubmit(
                        sessionId: id, cwd: LifecycleSuite.workspace
                    ),
                    entrypoint: "sdk"
                )
                usleep(500_000)
                a.expectEqual(app.status(of: id), "absent", "status")
            },

            TestCase("the script exits 0 even when the panel isn't there") { a in
                // The case that really matters: a failing hook can interrupt a
                // Claude Code turn, and nobody wants their work to stop because a
                // widget wasn't running.
                let script = app.home.appendingPathComponent(".lampboard/hook.sh")
                guard let source = try? String(contentsOf: script, encoding: .utf8) else {
                    return a.fail("script unreadable")
                }
                a.expect(source.contains("exit 0"), "the forced exit 0 is missing")
                a.expect(source.contains("|| true"), "the tolerance for curl's error is missing")
            },

            TestCase("uninstall-hooks removes only our registrations") { a in
                let result = app.runCommand(["uninstall-hooks"])
                a.expectEqual(result.status, 0, "exit code")

                let hooks = app.claudeSettings()["hooks"] as? [String: Any]
                a.expect(
                    hooks == nil || hooks?.isEmpty == true,
                    "registrations left behind: \(String(describing: hooks))"
                )
            },

            TestCase("each installation backs up the file it is about to change") { a in
                // And names the backup after that file. Both installers share the
                // code and only one of them writes a `settings.json`: Codex keeps
                // its hooks in `hooks.json`, and its backups carried the other
                // name. Nothing was lost by it, and somebody reading the
                // directory to undo a bad install finds a name for a file that
                // was never there.
                // Both files have to exist before the run: a backup of a file
                // that is not there is correctly no backup at all, and this case
                // must not depend on which case ran before it.
                let claudeSettings = app.home.appendingPathComponent(".claude/settings.json")
                if !FileManager.default.fileExists(atPath: claudeSettings.path) {
                    try? "{}".write(to: claudeSettings, atomically: true, encoding: .utf8)
                }
                let codexHooks = app.home.appendingPathComponent(".codex/hooks.json")
                try? FileManager.default.createDirectory(
                    at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? #"{"hooks":{}}"#.write(to: codexHooks, atomically: true, encoding: .utf8)

                app.runCommand(["install-hooks", "--port", String(app.port)])

                func entries(in folder: String) -> [String] {
                    (try? FileManager.default.contentsOfDirectory(
                        atPath: app.home.appendingPathComponent(folder).path
                    )) ?? []
                }
                let claude = entries(in: ".claude")
                a.expect(
                    claude.contains { $0.hasPrefix("settings.json.lampboard-backup-") },
                    "no Claude backup among: \(claude.joined(separator: ", "))"
                )
                let codex = entries(in: ".codex")
                a.expect(
                    codex.contains { $0.hasPrefix("hooks.json.lampboard-backup-") },
                    "no Codex backup under its own name among: \(codex.joined(separator: ", "))"
                )
            },

            TestCase("two installations in a row don't step on each other") { a in
                // The backup name carries the date down to the second. As long as
                // `copyItem` refused to overwrite, two closely spaced
                // installations — install, uninstall, reinstall in three clicks —
                // made the second one fail with a message about the backup while
                // it looked like a different problem.
                let first = app.runCommand(["install-hooks", "--port", String(app.port)])
                let second = app.runCommand(["install-hooks", "--port", String(app.port)])
                a.expectEqual(first.status, 0, "first installation: \(first.output)")
                a.expectEqual(second.status, 0, "second installation: \(second.output)")

                guard let hooks = app.claudeSettings()["hooks"] as? [String: Any] else {
                    return a.fail("no hooks key after the second installation")
                }
                a.expect(hooks["Stop"] != nil, "registrations lost")
            },

            TestCase("status reports the configuration it found") { a in
                let result = app.runCommand(["status"])
                a.expectEqual(result.status, 0, "exit code")
                a.expect(result.output.contains("Hook script"), "output: \(result.output)")
                a.expect(
                    result.output.contains("SubagentStart"),
                    "the registered events don't show up: \(result.output)"
                )
            },

            TestCase("sessions prints the live instance's column") { a in
                let result = app.runCommand(["sessions", "--port", String(app.port)])
                a.expectEqual(result.status, 0, "exit code — output: \(result.output)")
                // The command runs in a process that knows nothing about the
                // column: if it prints something, it really did talk to the app.
                a.expect(
                    result.output.contains("project-alpha")
                        || result.output.contains("project-beta"),
                    "output: \(result.output)"
                )
            },

            TestCase("the bare binary starts with the interface on as well") { a in
                // The test that was missing. All the rest of the suite runs
                // `--headless`, so it never went through `startInterface()`: and
                // in there `UNUserNotificationCenter.current()` terminated the
                // process with "bundleProxyForCurrentProcess is nil", because
                // outside a .app bundle that API raises an exception instead of
                // returning nil.
                //
                // A startup crash in a configuration no test walks through is the
                // easiest defect to ship, and this case exists so it can't be
                // shipped again.
                //
                // It is also a second instance, on another port, against the home
                // every other case shares — and its launch runs the token repair.
                // The first version of that repair reinstalled the hooks at its own
                // port, so this case quietly turned the whole installation towards
                // 9903 and the transcript cases below posted into the void. The
                // repair now leaves hooks addressed elsewhere alone; the token
                // lifecycle suite proves that in a home of its own.
                let process = Process()
                process.executableURL = app.binaryPath
                process.arguments = ["--port", "9903", "--skip-setup-prompt"]

                var environment = ProcessInfo.processInfo.environment
                environment[AppConfig.homeOverrideVariable] = app.home.path
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                guard (try? process.run()) != nil else {
                    return a.fail("process did not start")
                }
                defer {
                    if process.isRunning { process.terminate() }
                }

                // The crash, if there is one, comes immediately: it happens inside
                // `applicationDidFinishLaunching`.
                usleep(2_500_000)
                a.expect(
                    process.isRunning,
                    "the app died at startup, code \(process.terminationStatus)"
                )
            },

            TestCase("next with no panel answers without breaking") { a in
                // In headless mode there are no windows to raise: the route has to
                // say so, not pretend it did something.
                let result = app.raw(method: "POST", path: AppConfig.nextPath)
                a.expectEqual(result.status, 204, "status")
            },

            TestCase("next without a token is refused") { a in
                let result = app.raw(method: "POST", path: AppConfig.nextPath, token: .some(nil))
                a.expectEqual(result.status, 401, "status")
            },

            TestCase("GET on next is not allowed") { a in
                let result = app.raw(method: "GET", path: AppConfig.nextPath)
                a.expectEqual(result.status, 405, "status")
            },

            // MARK: - Slots

            TestCase("open with no panel answers 204, not an error") { a in
                // Headless: nothing to raise. The route has to say "understood,
                // nothing there" rather than report a failure — the same answer
                // an empty slot gives, because for the caller it is the same fact.
                let result = app.raw(
                    method: "POST", path: AppConfig.openPath, body: "1"
                )
                a.expectEqual(result.status, 204, "status")
            },

            TestCase("open without a token is refused") { a in
                let result = app.raw(
                    method: "POST", path: AppConfig.openPath, token: .some(nil), body: "1"
                )
                a.expectEqual(result.status, 401, "status")
            },

            TestCase("GET on open is not allowed") { a in
                let result = app.raw(method: "GET", path: AppConfig.openPath)
                a.expectEqual(result.status, 405, "status")
            },

            TestCase("open refuses a slot that isn't a number") { a in
                let result = app.raw(
                    method: "POST", path: AppConfig.openPath, body: "third"
                )
                a.expectEqual(result.status, 400, "status")
                a.expect(result.body.contains("1 to"), "the message says the range: \(result.body)")
            },

            TestCase("open refuses a slot outside the range") { a in
                for slot in ["0", "-1", String(AppConfig.maxSlots + 1)] {
                    let result = app.raw(
                        method: "POST", path: AppConfig.openPath, body: slot
                    )
                    a.expectEqual(result.status, 400, "slot \(slot)")
                }
            },

            TestCase("new answers 204 with no panel, and refuses like open does") { a in
                a.expectEqual(
                    app.raw(method: "POST", path: AppConfig.newConversationPath, body: "1").status,
                    204, "headless"
                )
                a.expectEqual(
                    app.raw(
                        method: "POST", path: AppConfig.newConversationPath,
                        token: .some(nil), body: "1"
                    ).status,
                    401, "no token"
                )
                a.expectEqual(
                    app.raw(method: "GET", path: AppConfig.newConversationPath).status,
                    405, "wrong method"
                )
                a.expectEqual(
                    app.raw(method: "POST", path: AppConfig.newConversationPath, body: "0").status,
                    400, "slot out of range"
                )
            },

            TestCase("chat answers 204 with no panel, and refuses like open does") { a in
                a.expectEqual(
                    app.raw(method: "POST", path: AppConfig.chatPath, body: "1").status,
                    204, "headless"
                )
                a.expectEqual(
                    app.raw(
                        method: "POST", path: AppConfig.chatPath, token: .some(nil), body: "1"
                    ).status,
                    401, "no token"
                )
                a.expectEqual(
                    app.raw(method: "GET", path: AppConfig.chatPath).status,
                    405, "wrong method"
                )
                a.expectEqual(
                    app.raw(method: "POST", path: AppConfig.chatPath, body: "0").status,
                    400, "slot out of range"
                )
            },

            // The path travels from the hook payload all the way out to the read
            // endpoint. Without it the chat window has nothing to open, and the
            // failure is silent: an empty conversation looks exactly like a
            // conversation where nothing was said.
            // The same chain, refusing. `POST /signal` carries no token by
            // design, and this value is opened for reading: measured on the
            // running app before the rule existed, a forged signal naming
            // /etc/passwd produced a row holding it within a second. The
            // signal is still accepted — a rejected hook would block a Claude
            // Code turn — but the path is dropped on the way in.
            TestCase("a transcript path outside ~/.claude is dropped, and the row still appears") { a in
                let id = "e2e-transcript-outside"
                app.writeLiveSession(sessionId: id, cwd: LifecycleSuite.workspace)

                var payload = HookPayloads.userPromptSubmit(
                    sessionId: id, cwd: LifecycleSuite.workspace
                )
                payload["transcript_path"] = "/etc/passwd"
                app.runHookScript(payload: payload)

                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "the row must still appear — status: \(app.status(of: id))"
                )
                guard let response = app.sessions(),
                      let session = response.sessions.first(where: { $0.id == id })
                else {
                    return a.fail("session not in the read endpoint")
                }
                a.expectNil(
                    session.transcriptPath,
                    "the app must not carry a path it would refuse to open"
                )
            },

            TestCase("the transcript path survives the whole chain") { a in
                let id = "e2e-transcript-path"
                // The live-session file first: by this point in the run the
                // realignment has a non-empty set of live processes, and a row
                // with no process behind it is removed within five seconds. A real
                // session has a process, so the test has one too — otherwise it
                // would be a race that passes on a fast machine.
                app.writeLiveSession(sessionId: id, cwd: LifecycleSuite.workspace)
                app.runHookScript(payload: HookPayloads.userPromptSubmit(
                    sessionId: id, cwd: LifecycleSuite.workspace
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "row not created — status: \(app.status(of: id))"
                )

                guard let response = app.sessions(),
                      let session = response.sessions.first(where: { $0.id == id })
                else {
                    return a.fail("session not in the read endpoint")
                }
                a.expectEqual(
                    session.transcriptPath, HookPayloads.transcriptPath(id),
                    "transcriptPath — the hook sent it, the endpoint has to publish it"
                )
                a.expectEqual(
                    session.entrypoint, "claude-vscode",
                    "entrypoint — the script read it from the environment and sent it as a header"
                )
            },

            TestCase("the sessions contract carries the slot field") { a in
                guard let response = app.sessions(), let first = response.sessions.first else {
                    return a.fail("no session to inspect")
                }
                // Every project seen gets a place in the order, and a place in
                // the first nine is a slot — so in a fresh test home the first
                // project holds one. The field is the only way an outside reader
                // can know what a key addresses.
                guard let slot = first.slot else { return a.fail("the first project seen has no slot") }
                a.expect((1...AppConfig.maxSlots).contains(slot), "slot \(slot) in range")
            },
        ])
    }
}
