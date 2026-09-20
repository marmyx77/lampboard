import LampBoardCore
import Foundation
import TestKit

enum HookConfigMergerSuite {

    private static let scriptPath = "/Users/dev/.lampboard/hook.sh"

    /// A realiztic settings.json: it already holds user configuration that the
    /// installation must not touch.
    private static var existingSettings: [String: Any] {
        [
            "model": "opus[1m]",
            "language": "Italian",
            "permissions": ["defaultMode": "auto"],
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Bash",
                        "hooks": [
                            ["type": "command", "command": "/Users/dev/.claude/guard.sh"]
                        ],
                    ] as [String: Any]
                ]
            ],
        ]
    }

    private static func entries(
        _ settings: [String: Any], event: String
    ) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    static let suite = TestSuite("Hook registration in settings.json", [

        TestCase("Registers all the default events") { t in
            let result = HookConfigMerger.install(into: [:], scriptPath: scriptPath)

            t.expectEqual(
                HookConfigMerger.installedEvents(in: result, scriptPath: scriptPath),
                HookConfigMerger.defaultEvents.sorted()
            )
        },

        TestCase("Leaves the other configuration keys alone") { t in
            let result = HookConfigMerger.install(into: existingSettings, scriptPath: scriptPath)

            t.expectEqual(result["model"] as? String, "opus[1m]", "model")
            t.expectEqual(result["language"] as? String, "Italian", "language")
            t.expectNotNil(result["permissions"], "permissions")
        },

        // The case that would ruin somebody's day: overwriting the user's hooks.
        TestCase("Preserves pre-existing hooks on the same event") { t in
            let result = HookConfigMerger.install(
                into: existingSettings, scriptPath: scriptPath,
                events: HookConfigMerger.defaultEvents + HookConfigMerger.toolEvents
            )

            let preToolUse = entries(result, event: "PreToolUse")
            t.expectEqual(preToolUse.count, 2, "groups on PreToolUse")

            let commands = preToolUse.flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
            t.expect(commands.contains("/Users/dev/.claude/guard.sh"), "user hook lost")
            t.expect(commands.contains(scriptPath), "lampboard hook missing")
        },

        TestCase("Installing twice does not duplicate the registrations") { t in
            let once = HookConfigMerger.install(into: existingSettings, scriptPath: scriptPath)
            let twice = HookConfigMerger.install(into: once, scriptPath: scriptPath)

            t.expectEqual(entries(twice, event: "Stop").count, 1, "groups on Stop")
            t.expectEqual(
                HookConfigMerger.installedEvents(in: twice, scriptPath: scriptPath),
                HookConfigMerger.defaultEvents.sorted()
            )
        },

        TestCase("Changing the event list leaves no orphaned registrations") { t in
            let wide = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                events: HookConfigMerger.defaultEvents + HookConfigMerger.toolEvents
            )
            let narrow = HookConfigMerger.install(into: wide, scriptPath: scriptPath)

            t.expectEqual(
                HookConfigMerger.installedEvents(in: narrow, scriptPath: scriptPath),
                HookConfigMerger.defaultEvents.sorted()
            )
        },

        TestCase("Uninstalling removes only our hooks") { t in
            let installed = HookConfigMerger.install(into: existingSettings, scriptPath: scriptPath)
            let removed = HookConfigMerger.uninstall(from: installed, scriptPath: scriptPath)

            t.expect(
                !HookConfigMerger.isInstalled(in: removed, scriptPath: scriptPath),
                "the lampboard hooks are still there"
            )
            let userHooks = entries(removed, event: "PreToolUse")
            t.expectEqual(userHooks.count, 1, "the user's hook should have stayed")
        },

        TestCase("Uninstalling from a configuration with no hooks breaks nothing") { t in
            let settings: [String: Any] = ["model": "opus"]
            let result = HookConfigMerger.uninstall(from: settings, scriptPath: scriptPath)

            t.expectEqual(result["model"] as? String, "opus", "model")
            t.expectNil(result["hooks"], "hooks")
        },

        TestCase("The hooks key disappears when it's left empty") { t in
            let installed = HookConfigMerger.install(into: [:], scriptPath: scriptPath)
            let removed = HookConfigMerger.uninstall(from: installed, scriptPath: scriptPath)

            t.expectNil(removed["hooks"], "hooks")
        },

        TestCase("isInstalled tells different scripts apart") { t in
            let installed = HookConfigMerger.install(into: [:], scriptPath: scriptPath)

            t.expect(HookConfigMerger.isInstalled(in: installed, scriptPath: scriptPath), "our script")
            t.expect(
                !HookConfigMerger.isInstalled(in: installed, scriptPath: "/other/hook.sh"),
                "a different script must not count as installed"
            )
        },

        TestCase("Every registration has a type, a command and a timeout") { t in
            let result = HookConfigMerger.install(into: [:], scriptPath: scriptPath)
            guard let entry = entries(result, event: "Stop").first?["hooks"] as? [[String: Any]],
                  let hook = entry.first else {
                return t.fail("registration on Stop missing")
            }

            t.expectEqual(hook["type"] as? String, "command", "type")
            t.expectEqual(hook["command"] as? String, scriptPath, "command")
            t.expectNotNil(hook["timeout"], "timeout")
        },

        // MARK: - The native http form

        TestCase("With an endpoint, the turn's events post natively") { t in
            let result = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: "abc")
            )
            let types = HookConfigMerger.defaultEvents.map { event -> String in
                let group = entries(result, event: event).first ?? [:]
                let hook = (group["hooks"] as? [[String: Any]])?.first ?? [:]
                return (hook["type"] as? String) ?? "missing"
            }
            let expected = HookConfigMerger.defaultEvents.map {
                HookConfigMerger.commandOnlyEvents.contains($0) ? "command" : "http"
            }
            t.expectEqual(types, expected, "one form per event")
        },

        // Both exceptions were measured, and both fail in ways nobody would blame
        // on the hooks: SessionStart simply never arrives, SessionEnd prints a
        // connection error to whoever is typing.
        TestCase("SessionStart and SessionEnd keep running the script") { t in
            let result = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: "abc")
            )
            for event in ["SessionStart", "SessionEnd"] {
                let hook = ((entries(result, event: event).first?["hooks"]) as? [[String: Any]])?.first
                t.expectEqual(hook?["command"] as? String, scriptPath, event)
            }
        },

        TestCase("The http hook carries the token, the harness and the entrypoint") { t in
            let result = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: "sekret")
            )
            let hook = ((entries(result, event: "PostToolUse").first?["hooks"]) as? [[String: Any]])?.first
            let headers = hook?["headers"] as? [String: String] ?? [:]
            t.expectEqual(hook?["url"] as? String, "http://127.0.0.1:9877/signal", "url")
            t.expectEqual(headers[AccessToken.headerName], "sekret", "token header")
            t.expectEqual(headers[AppConfig.harnessHeader], Harness.claudeCode.rawValue, "harness header")
            // Interpolated by Claude Code, and only because the variable is listed:
            // anything left out of allowedEnvVars resolves to an empty string.
            t.expectEqual(headers[AppConfig.entrypointHeader], "$CLAUDE_CODE_ENTRYPOINT", "entrypoint")
            t.expectEqual(hook?["allowedEnvVars"] as? [String], ["CLAUDE_CODE_ENTRYPOINT"], "allowed")
        },

        TestCase("Without an endpoint every event still runs the script") { t in
            let result = HookConfigMerger.install(into: [:], scriptPath: scriptPath)
            let urls = HookConfigMerger.defaultEvents.compactMap { event -> String? in
                let hook = ((entries(result, event: event).first?["hooks"]) as? [[String: Any]])?.first
                return hook?["url"] as? String
            }
            t.expect(urls.isEmpty, "Codex has no http hooks to offer: \(urls)")
        },

        TestCase("An endpoint with no token installs a hook without the header") { t in
            let result = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: nil)
            )
            let hook = ((entries(result, event: "PostToolUse").first?["hooks"]) as? [[String: Any]])?.first
            let headers = hook?["headers"] as? [String: String] ?? [:]
            t.expectNil(headers[AccessToken.headerName], "no token header")
            t.expectNotNil(hook?["url"], "but still a hook")
        },

        TestCase("A remote endpoint names its host and its own port") { t in
            let endpoint = HookConfigMerger.endpoint(
                port: 31000, token: "abc", harness: .claudeCode, host: "minisforum"
            )
            t.expectEqual(endpoint.url, "http://127.0.0.1:31000/signal", "the far side's loopback")
            t.expectEqual(endpoint.headers[AppConfig.remoteHostHeader], "minisforum", "host header")
        },

        // MARK: - Recognising our own registrations

        TestCase("Our endpoint is recognised, other people's URLs are not") { t in
            t.expect(HookConfigMerger.isOurEndpoint("http://127.0.0.1:9877/signal"), "local")
            t.expect(HookConfigMerger.isOurEndpoint("http://127.0.0.1:31000/signal"), "any port")
            t.expect(HookConfigMerger.isOurEndpoint("http://localhost:9877/signal"), "localhost")
            t.expect(!HookConfigMerger.isOurEndpoint("http://127.0.0.1:4317/hook"), "a neighbour's")
            t.expect(!HookConfigMerger.isOurEndpoint("http://example.com/signal"), "off the machine")
            t.expect(!HookConfigMerger.isOurEndpoint("http://127.0.0.1:9877/sessions"), "another route")
        },

        TestCase("Uninstalling removes both forms and leaves nothing behind") { t in
            let installed = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: "abc")
            )
            let cleaned = HookConfigMerger.uninstall(from: installed, scriptPath: scriptPath)
            t.expectNil(cleaned["hooks"], "not one registration survives")
        },

        // The shape found on the node this panel actually watches: our nine hooks
        // registered under the name the project had before, plus somebody else's
        // hook on UserPromptSubmit. An upgrade has to recognise the first — leaving
        // a second copy on every event would double every signal while looking like
        // it worked — and must not touch the second.
        TestCase("An upgrade from the old script replaces it and spares the neighbour") { t in
            let oldPath = "/home/dev/.clawd-light/hook.sh"
            let guardHook = "python3 /home/dev/.claude/hooks/blocca-chiavi.py"
            var before = HookConfigMerger.install(into: [:], scriptPath: oldPath)
            var hooks = before["hooks"] as! [String: Any]
            let existing = hooks["UserPromptSubmit"] as! [[String: Any]]
            hooks["UserPromptSubmit"] = existing + [
                ["hooks": [["type": "command", "command": guardHook]]] as [String: Any]
            ]
            before["hooks"] = hooks

            let after = HookConfigMerger.uninstall(from: before, scriptPaths: [oldPath])
            let upgraded = HookConfigMerger.install(
                into: after, scriptPath: "/home/dev/.lampboard/hook.sh",
                rewakeScriptPath: nil, registerMessageDelivery: false,
                endpoint: HookConfigMerger.endpoint(
                    port: 31000, token: "abc", harness: .claudeCode, host: "minisforum"
                )
            )

            let prompts = entries(upgraded, event: "UserPromptSubmit").flatMap {
                ($0["hooks"] as? [[String: Any]]) ?? []
            }
            t.expectEqual(prompts.count, 2, "the neighbour and exactly one of ours")
            t.expect(
                prompts.contains { ($0["command"] as? String) == guardHook },
                "the neighbour's hook was removed"
            )
            t.expect(
                prompts.contains { ($0["type"] as? String) == "http" },
                "ours did not become the native form"
            )
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: upgraded), as: UTF8.self)
            t.expect(!text.contains(".clawd-light"), "the old script is still registered somewhere")
        },
    ])
}

enum HookScriptBuilderSuite {

    static let suite = TestSuite("Hook script generation", [

        TestCase("Contains the right shebang, port and path") { t in
            let script = HookScriptBuilder.script(port: 9877)

            t.expect(script.hasPrefix("#!/bin/bash"), "shebang missing")
            t.expect(script.contains("http://127.0.0.1:9877/signal"), "wrong URL in:\n\(script)")
            t.expect(script.contains("X-Claude-Entrypoint"), "entrypoint header missing")
        },

        // A failing hook can interrupt a Claude Code turn.
        TestCase("Always exits 0") { t in
            let script = HookScriptBuilder.script()

            t.expect(script.contains("exit 0"), "the forced exit 0 is missing")
            t.expect(script.contains("|| true"), "curl can make the script fail")
        },

        TestCase("Has short timeouts so it doesn't slow the turn down") { t in
            let script = HookScriptBuilder.script()

            t.expect(script.contains("--connect-timeout 1"), "connect-timeout missing")
            t.expect(script.contains("--max-time 2"), "max-time missing")
        },

        TestCase("Honors the requested port") { t in
            t.expect(
                HookScriptBuilder.script(port: 12345).contains(":12345/signal"),
                "the port is not propagated"
            )
        },

        // The script installed on another machine has to say which machine, or
        // its signals would be looked up among local editor windows and dropped.
        TestCase("A script for another machine names it in a header and posts to its own port") { t in
            let remote = HookScriptBuilder.script(port: 31000, host: "node")
            // Presence and order, not adjacency. The two used to be checked as one
            // string, which made the case fail the moment anything was added
            // between them — and curl does not care what order its flags come in.
            // What matters is that the header is there and belongs to this request.
            guard let header = remote.range(of: "--header 'X-LampBoard-Host: node'"),
                  let body = remote.range(of: "--data-binary")
            else {
                return t.fail("host header or body missing in:\n\(remote)")
            }
            t.expect(header.upperBound < body.lowerBound, "the host header is not part of the post")
            t.expect(remote.contains("posts through the ssh tunnel"), "the script says where it runs")
            // The per-user loopback port the tunnel binds over there — never the
            // Mac's own port, which another account on that machine could share.
            t.expect(remote.contains("'http://127.0.0.1:31000/signal'"), "posts to the tunnel's far end in:\n\(remote)")
            t.expect(!HookScriptBuilder.script(port: 9877).contains("X-LampBoard-Host"), "a local script carries no host")
        },

        TestCase("The remote port is the user's, and both sides compute it the same way") { t in
            t.expectEqual(AppConfig.remotePort(forUID: 1000), 31000, "uid 1000")
            t.expectEqual(AppConfig.remotePort(forUID: 0), 30000, "root, should anyone")
            t.expectEqual(AppConfig.remotePort(forUID: 21000), 31000, "wraps inside the range")
            t.expect(
                RemoteInstallScripts.prepareTunnel.contains("30000 + max(uid, 0) % 20000"),
                "the Python formula must stay textually identical to AppConfig.remotePort"
            )
        },

        // The boundary that keeps "any process on your machine can start a turn in
        // your voice" (D15) from extending to every process on the node.
        TestCase("The remote merge registers no message delivery") { t in
            let merged = HookConfigMerger.install(
                into: [:], scriptPath: "/home/dev/.lampboard/hook.sh",
                rewakeScriptPath: nil, registerMessageDelivery: false
            )
            let hooks = (merged["hooks"] as? [String: Any]) ?? [:]
            let stop = (hooks["Stop"] as? [[String: Any]]) ?? []
            t.expectEqual(stop.count, 1, "one Stop group: the traffic light's")
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: merged), as: UTF8.self)
            t.expect(!text.contains("asyncRewake") && !text.contains("rewake"), "no rewake anywhere in the remote settings")
        },


        // MARK: - The session's git identity

        TestCase("An identity needs at least one name") { t in
            t.expectNil(GitIdentity.from(repo: nil, branch: nil, worktree: "true"), "nothing to say")
            t.expectNil(GitIdentity.from(repo: "  ", branch: "", worktree: nil), "blank is nothing")
            t.expectNotNil(GitIdentity.from(repo: "app", branch: nil, worktree: nil), "repo alone")
            t.expectNotNil(GitIdentity.from(repo: nil, branch: "main", worktree: nil), "branch alone")
        },

        TestCase("The worktree flag is the header's presence, not its value") { t in
            t.expect(
                GitIdentity.from(repo: "app", branch: "main", worktree: "true")?.isWorktree == true,
                "present"
            )
            t.expect(
                GitIdentity.from(repo: "app", branch: "main", worktree: nil)?.isWorktree == false,
                "absent"
            )
            // The script sends the header only when it has decided the answer is
            // yes, so any value at all means yes — and an empty one means it was
            // never decided.
            t.expect(
                GitIdentity.from(repo: "app", branch: "main", worktree: "  ")?.isWorktree == false,
                "blank is not a decision"
            )
        },

        TestCase("The card line says the worktree in words") { t in
            t.expectEqual(
                GitIdentity(repo: "app", branch: "main").summary, "app · main", "plain"
            )
            t.expectEqual(
                GitIdentity(repo: "app", branch: nil, isWorktree: true).summary,
                "app (worktree)", "a detached worktree still names the main repository"
            )
            t.expectEqual(GitIdentity(repo: nil, branch: "main").summary, "main", "branch alone")
            t.expectNil(GitIdentity(repo: nil, branch: nil).summary, "nothing to draw")
        },

        // The script resolves git only on a session start; every later event
        // arrives without it. A setter that could take nil would let the next Stop
        // erase a perfectly good branch name, so there is no way to express that.
        TestCase("A later signal cannot erase the branch") { t in
            let script = HookScriptBuilder.script()
            t.expect(script.contains("SessionStart"), "the script gates the git work on the event")
            t.expect(
                script.contains("symbolic-ref --short HEAD"),
                "rev-parse --abbrev-ref prints the word HEAD for a detached head"
            )
            t.expect(
                script.contains("--path-format=absolute"),
                "without it every subdirectory of a repository reads as a worktree"
            )
        },
    ])
}
