import LampBoardCore
import Foundation
import TestKit

/// The rule behind the launch repair, and behind the same repair on a node.
///
/// Every case here is a question the first version of the repair never asked —
/// whose installation is this, what shape does it have — and each was found by
/// watching a test instance on another port rewrite a shared installation (D48).
enum HookRepairSuite {

    private static let scriptPath = "/home/dev/.lampboard/hook.sh"
    private static let rewakePath = "/home/dev/.lampboard/rewake.sh"
    private static let token = "0123456789abcdef0123456789abcdef0123456789abcdef"

    private static func verdict(
        _ settings: [String: Any], script: String?, port: UInt16 = 9877, rewake: String? = rewakePath
    ) -> HookRepair.Verdict {
        HookRepair.verdict(
            settings: settings, scriptPath: scriptPath, rewakeScriptPath: rewake,
            scriptText: script, token: token, port: port
        )
    }

    /// The shape found on the node this panel watches, 20 September 2026, with
    /// the names changed: nine command hooks under the project's previous name,
    /// and somebody else's hook sharing an event. The fixture the scripts are
    /// rehearsed against as well.
    static let legacyRelativePath = AppConfig.legacyRemoteHookScriptRelativePath
    static let neighbourCommand = "python3 /home/dev/.claude/hooks/guard.py"

    static func previousNameInstallation(home: String) -> [String: Any] {
        let legacy = home + "/" + legacyRelativePath
        let ours: [String: Any] = ["hooks": [
            ["type": "command", "command": legacy, "timeout": 3] as [String: Any]
        ]]
        var hooks: [String: Any] = [:]
        for event in HookConfigMerger.defaultEvents where event != "PostToolUseFailure" {
            hooks[event] = [ours]
        }
        hooks["UserPromptSubmit"] = [
            ours,
            ["hooks": [["type": "command", "command": neighbourCommand]]] as [String: Any],
        ]
        return ["hooks": hooks, "model": "opus"]
    }

    static let suite = TestSuite("Hook repair", [

        // The commonest stale installation there is, and the one the first rule
        // read as "nothing installed": every node set up before the rename.
        TestCase("An installation under the previous name is ours to bring forward") { t in
            let home = "/home/dev"
            let settings = previousNameInstallation(home: home)
            let legacy = home + "/" + legacyRelativePath
            let script = HookScriptBuilder.script(port: 31000, host: "node", token: nil)
            let current = home + "/" + AppConfig.remoteHookScriptRelativePath

            t.expectEqual(
                HookRepair.verdict(
                    settings: settings, scriptPath: current, rewakeScriptPath: nil,
                    scriptText: script, token: token, port: 31000
                ),
                .nothingInstalled,
                "without the previous name, the rule is blind to it — which is the defect"
            )
            t.expectEqual(
                HookRepair.verdict(
                    settings: settings, scriptPath: current, legacyScriptPaths: [legacy],
                    rewakeScriptPath: nil, scriptText: script, token: token, port: 31000
                ),
                .stale(HookRepair.Shape(includeToolEvents: false, includeMessageDelivery: false)),
                "its own port, no token: stale, plain shape"
            )
            t.expectEqual(
                HookRepair.verdict(
                    settings: settings, scriptPath: current, legacyScriptPaths: [legacy],
                    rewakeScriptPath: nil, scriptText: script, token: token, port: 31001
                ),
                .addressedElsewhere,
                "another user's tunnel port"
            )

            // Brought forward: nothing left under the old name, the neighbour untouched.
            let merged = HookConfigMerger.install(
                into: settings, scriptPath: current, rewakeScriptPath: nil,
                registerMessageDelivery: false,
                endpoint: HookConfigMerger.endpoint(port: 31000, token: token, host: "node"),
                legacyScriptPaths: [legacy]
            )
            t.expect(!HookConfigMerger.hasCommandHook(at: legacy, in: merged), "the old path survived")
            t.expect(HookConfigMerger.hasCommandHook(at: neighbourCommand, in: merged), "the neighbour was taken")
            t.expectEqual(HookConfigMerger.nativePorts(in: merged), [31000], "posting where it did")
            t.expect(
                HookConfigMerger.installedEvents(in: merged, scriptPath: current).contains("PostToolUseFailure"),
                "the event added since is registered by the migration"
            )
            t.expectEqual(merged["model"] as? String, "opus", "the rest of the file is untouched")
        },


        TestCase("Nothing installed is nothing to repair") { t in
            t.expectEqual(verdict([:], script: nil), .nothingInstalled, "empty settings")
            let theirs: [String: Any] = ["hooks": ["Stop": [
                ["hooks": [["type": "http", "url": "http://127.0.0.1:4317/hook"]]] as [String: Any]
            ]]]
            t.expectEqual(verdict(theirs, script: nil), .nothingInstalled, "a neighbour's hook is not ours")
        },

        TestCase("An installation addressed to another listener is left alone") { t in
            let installed = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: nil)
            )
            let script = HookScriptBuilder.script(port: 9877, token: nil)
            t.expectEqual(verdict(installed, script: script, port: 9903), .addressedElsewhere, "native URLs say 9877")
            t.expect(verdict(installed, script: script, port: 9877) != .addressedElsewhere, "the same file, asked by 9877")
        },

        // Codex, and every installation written before 0.4: no native hook, so
        // the script's own target is the record of where it posts.
        TestCase("A script-only installation is addressed by its script, or by nobody") { t in
            let onScript = HookConfigMerger.install(into: [:], scriptPath: scriptPath)
            let script = HookScriptBuilder.script(port: 9877, token: nil)
            t.expectEqual(
                verdict(onScript, script: script),
                .stale(HookRepair.Shape(includeToolEvents: false, includeMessageDelivery: false)),
                "its own port, no token: stale"
            )
            t.expectEqual(verdict(onScript, script: script, port: 9903), .addressedElsewhere, "another port")
            t.expectEqual(verdict(onScript, script: nil), .addressedElsewhere, "no script, no native hook: nobody's")
        },

        TestCase("Both halves carrying the token is current, either half without it is stale") { t in
            let native = HookConfigMerger.endpoint(port: 9877, token: token)
            let installed = HookConfigMerger.install(into: [:], scriptPath: scriptPath, endpoint: native)
            let withToken = HookScriptBuilder.script(port: 9877, token: token)
            let without = HookScriptBuilder.script(port: 9877, token: nil)
            t.expectEqual(verdict(installed, script: withToken), .current, "both halves")

            let plain = HookRepair.Shape(includeToolEvents: false, includeMessageDelivery: false)
            t.expectEqual(verdict(installed, script: without), .stale(plain), "script without")
            t.expectEqual(verdict(installed, script: nil), .stale(plain), "script missing")
            let headerless = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: nil)
            )
            t.expectEqual(verdict(headerless, script: withToken), .stale(plain), "header without")
            let wrong = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: "other")
            )
            t.expectEqual(verdict(wrong, script: withToken), .stale(plain), "somebody else's token")
        },

        // The defect the case above found in the first committed version: the
        // listener was detected with `isInstalled`, which also claims native
        // hooks, so every native installation read as having message delivery on
        // — and the repair would have registered the mailbox for people who had
        // never turned it on. That is the one feature here that lets a process on
        // the machine start a turn in the person's voice (D15).
        TestCase("A native installation without the listener never gains one") { t in
            let installed = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: nil)
            )
            t.expect(
                !HookConfigMerger.hasCommandHook(at: rewakePath, in: installed),
                "the listener was seen where there is none"
            )
            t.expect(
                HookConfigMerger.isInstalled(in: installed, scriptPath: rewakePath),
                "the trap is real: isInstalled claims the native hooks for any path"
            )
            guard case .stale(let shape) = verdict(installed, script: nil) else {
                return t.fail("a tokenless installation is stale")
            }
            t.expect(!shape.includeMessageDelivery, "message delivery must stay off")
        },

        // What was there is what stays: a repair that reset the optional
        // registrations would have taken PreToolUse and the message listener away
        // from everybody who had turned them on.
        TestCase("The shape found is the shape kept") { t in
            let full = HookConfigMerger.install(
                into: [:], scriptPath: scriptPath, rewakeScriptPath: rewakePath,
                registerMessageDelivery: true,
                events: HookConfigMerger.defaultEvents + HookConfigMerger.toolEvents,
                endpoint: HookConfigMerger.endpoint(port: 9877, token: nil)
            )
            let script = HookScriptBuilder.script(port: 9877, token: nil)
            t.expectEqual(
                verdict(full, script: script),
                .stale(HookRepair.Shape(includeToolEvents: true, includeMessageDelivery: true)),
                "tool events and the listener, both kept"
            )
            // A node has no listener to keep, whatever the file says.
            t.expectEqual(
                verdict(full, script: script, rewake: nil),
                .stale(HookRepair.Shape(includeToolEvents: true, includeMessageDelivery: false)),
                "no rewake path, no delivery"
            )
        },
    ])
}
