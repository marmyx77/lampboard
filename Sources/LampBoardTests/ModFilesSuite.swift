import LampBoardCore
import Foundation
import TestKit

/// The mod the app installs, and the mod the repository publishes.
///
/// The only domain suite that reads a file: the repository's own copy of the
/// mod, found from this source file's path. Two copies of one program drift the
/// first time somebody edits one of them, and this is where that is caught.
enum ModFilesSuite {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let records = Data(#"""
        {"version":2,"plugins":{"lampboard@lampboard":[{"scope":"user","version":"1.0.0",
        "installedAt":"2026-10-04T17:22:02.311Z"}]}}
        """#.utf8)

    static let suite = TestSuite("The companion mod's files and installation", [

        TestCase("The files the app writes are the repository's, byte for byte") { t in
            for file in ModFiles.all {
                let onDisk = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8)
                t.expectEqual(onDisk, file.content, file.path)
            }
        },

        TestCase("The version in the plugin's manifest is the one the panel compares") { t in
            t.expect(ModFiles.plugin.contains("\"version\": \"\(ModFiles.version)\""), "plugin.json says \(ModFiles.version)")
        },

        TestCase("The mod talks to loopback only, and writes and runs nothing") { t in
            let code = ModFiles.register
            t.expect(code.contains("http://127.0.0.1:"), "posts to loopback")
            for call in ["$.fs.write", "$.process", "$.prompt", "$.tool", "$.session.messages"] {
                t.expect(!code.contains(call), "the mod must not use \(call)")
            }
            // Of the model, two forks and nothing else: the panel's proven side
            // question (D82), and the handoff the person asks for with /handoff
            // (D91). No completion of its own, no turn.
            t.expectEqual(code.components(separatedBy: "$.model.").count - 1, 2, "two model calls in all")
            t.expect(code.contains("await $.model.fork({ prompt: question })"), "the side question's fork")
            t.expect(code.contains("await $.model.fork({ prompt: HANDOFF_QUESTION })"), "the handoff's fork, its question fixed")
            t.expect(!code.contains("https://"), "no address beyond this Mac")
        },

        TestCase("A side question is taken before the session reads it, and answered only when proven (D82)") { t in
            let code = ModFiles.register
            t.expect(code.contains("return { consumed: 'lampboard-ask' }"), "taken, proven or not")
            t.expect(code.contains("if (!text.startsWith('LampBoard asks without disturbing [')) return next(e)"),
                     "anything else passes untouched, and the line's head is PeerAsk's")
            t.expect(code.contains("LampBoard asks without disturbing ["), "the head the mod looks for")
            t.expect(code.contains("hmac(key, `fork:${nonce}:${session}:${question}`)"), "the proof PeerAsk makes")
            t.expect(code.contains("/.lampboard/check-key`"), "with the permission key, never the token")
            t.expect(code.contains("features: ['ask']"), "and the start says it can")
        },

        TestCase("The band shows and opens; it answers nothing, and draws nothing when nothing waits (D84)") { t in
            let code = ModFiles.register
            t.expect(code.contains("${target.base}\(AppConfig.bandPath)`"), "asks the band's route")
            t.expect(code.contains("${target.base}\(AppConfig.bandOpenPath)`"), "and opens through its own")
            t.expect(!code.contains("check/answer"), "never the answer route: a permission is a click in the panel")
            t.expect(code.contains("if (items.length === 0 || (e.props && e.props.hasSurvey)) return next(e)"), "the engine's own band when empty")
            t.expect(code.contains("if (e.isInteractive && !bands.has(session))"), "one clock per session, where a person reads")
            t.expect(code.contains("clearInterval(ending.clock)"), "stopped when its session ends")
        },

        TestCase("A question goes to the panel proven, and only a signed choice answers it (D86)") { t in
            let code = ModFiles.register
            t.expect(code.contains("/question`"), "the question's route")
            t.expect(code.contains("hmac(key, `question:${nonce}:${session}:${e.tool_use_id}`)"), "proven under its own prefix")
            t.expect(code.contains("same(signature, await hmac(key, `choose:${nonce}:${index}`))"), "the choice signed")
            t.expect(code.contains("if (q.multiSelect || (q.kind && q.kind !== 'choice') || options.length < 2 || options.length > 4) return null"),
                     "only what a card can show")
        },

        TestCase("An edit's or a write's lines go to the panel as counts, never as text (D87)") { t in
            let code = ModFiles.register
            t.expect(code.contains("lines: linesOf(e.tool, e.input || {})"), "the counts with the ask")
            t.expect(code.contains("more: goesOn(e.input || {})"), "and whether the command goes on past its first line")
            t.expect(code.contains("return { removed: count(input.old_string), added: count(input.new_string) }"), "numbers only")
        },

        TestCase("/lampmaster asks through the MCP tool's route and name, and hands the model nothing") { t in
            let code = ModFiles.register
            t.expect(code.contains("name: 'lampmaster'"), "registers /lampmaster")
            t.expect(code.contains("{ command: 'lampmaster' }"), "answers its own command only")
            t.expect(code.contains("${target.base}\(AppConfig.lampMasterToolPath)"), "the route the server serves")
            t.expect(code.contains("tool: '\(LampMasterMCP.Tool.askLampMaster.rawValue)'"), "the tool the server knows")
            // An answer is the person's to read (D71): a `context` entry would be
            // a hidden message to the model, made of other sessions' work.
            t.expect(!code.contains("context: ["), "no note left for the model")
        },

        TestCase("Installed through Claude Code's own commands, and taken out with its marketplace") { t in
            t.expectEqual(ModRegistration.installSteps(folder: "/x/mod-marketplace"), [
                ["plugin", "marketplace", "add", "/x/mod-marketplace"],
                ["plugin", "install", "lampboard@lampboard", "--scope", "user"],
            ])
            t.expectEqual(ModRegistration.uninstallSteps.last, ["plugin", "marketplace", "remove", "lampboard"])
        },

        TestCase("Enabled is read from the settings Claude Code wrote") { t in
            let on = Data(#"{"enabledPlugins":{"lampboard@lampboard":true}}"#.utf8)
            let off = Data(#"{"enabledPlugins":{"lampboard@lampboard":false}}"#.utf8)
            t.expect(ModRegistration.isEnabled(settings: on), "on")
            t.expect(!ModRegistration.isEnabled(settings: off), "off")
            t.expect(!ModRegistration.isEnabled(settings: nil), "no file")
            t.expect(!ModRegistration.isEnabled(settings: Data("{".utf8)), "unreadable")
        },

        TestCase("A marketplace still declared is seen in either of Claude Code's files") { t in
            let settings = Data(#"{"extraKnownMarketplaces":{"lampboard":{"source":{"source":"directory","path":"/x"}}}}"#.utf8)
            let known = Data(#"{"lampboard":{"installLocation":"/x"}}"#.utf8)
            t.expect(ModRegistration.isMarketplaceDeclared(settings: settings, known: nil), "settings")
            t.expect(ModRegistration.isMarketplaceDeclared(settings: nil, known: known), "list")
            t.expect(!ModRegistration.isMarketplaceDeclared(settings: Data("{}".utf8), known: Data(#"{"other":{}}"#.utf8)), "neither")
        },

        TestCase("The installed version is found in Claude Code's records") { t in
            t.expectEqual(ModRegistration.installedVersion(records: records), "1.0.0")
            t.expectNil(ModRegistration.installedVersion(records: Data(#"{"version":2,"plugins":{}}"#.utf8)))
        },

        TestCase("Mods from 2.1.287; an unreadable version is given the benefit") { t in
            t.expect(!ModRegistration.isSupported(by: ReleaseVersion("2.1.286")), "2.1.286")
            t.expect(ModRegistration.isSupported(by: ReleaseVersion("2.1.287")), "2.1.287")
            t.expect(ModRegistration.isSupported(by: nil), "unknown")
        },
    ])
}
