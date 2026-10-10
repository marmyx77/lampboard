import Foundation
import LampBoardCore
import TestKit

// The live view's look (D142–D146): its themes, the colours read from VS Code,
// the fonts it may use and how tightly they are set; and the helper beside the
// hooks of other machines.
/// The look of 1.4 (D142, D143): VS Code's colours in the live view, and the
/// helper beside the hooks on other machines.
enum LookOfVSCodeSuite {
    static let suite = TestSuite("VS Code's colours, and the helper everywhere", [

        TestCase("The VS Code themes bring VS Code's sixteen terminal colours; the others keep the terminal's") { t in
            for id in ["vscode-light", "vscode-dark"] {
                let theme = LiveTheme.named(id)
                t.expectEqual(theme.id, id)
                t.expectEqual(theme.ansi?.count, 16, id)
                t.expect(theme.ansi?.allSatisfy { LiveTheme.rgb($0) != nil } == true, "\(id): every colour reads")
            }
            t.expectNil(LiveTheme.named("night").ansi)
            t.expect(!LiveTheme.named("vscode-light").isDark && LiveTheme.named("vscode-dark").isDark, "light and dark")
        },

        TestCase("An appearance holds its numbers to the ranges, and an empty family is the system's") { t in
            let a = LiveAppearance(theme: LiveTheme.named(nil), fontSize: 99, fontFamily: "  ", lineSpacing: 3)
            t.expectEqual(a.fontSize, LiveTheme.fontSizes.upperBound)
            t.expectNil(a.fontFamily)
            t.expectEqual(a.lineSpacing, LiveTheme.lineSpacings.upperBound)
            t.expectEqual(LiveAppearance(theme: LiveTheme.named(nil), fontSize: 13, fontFamily: "Menlo").fontFamily, "Menlo")
        },

        TestCase("The helper goes beside the hooks, and up to this version; never where nobody connected") { t in
            t.expect(RemoteModPolicy.shouldInstall(hooksThere: true, modThere: nil, ours: "1.15.0"), "hooks, no helper")
            t.expect(!RemoteModPolicy.shouldInstall(hooksThere: false, modThere: nil, ours: "1.15.0"), "nothing there")
            t.expect(RemoteModPolicy.shouldInstall(hooksThere: true, modThere: "1.14.0", ours: "1.15.0"), "older")
            t.expect(!RemoteModPolicy.shouldInstall(hooksThere: true, modThere: "1.15.0", ours: "1.15.0"), "same")
            t.expect(!RemoteModPolicy.shouldInstall(hooksThere: true, modThere: "1.16.0", ours: "1.15.0"), "newer stays")
        },
    ])
}

/// «Like my VS Code» (D144): the colours read from VS Code's own files.
enum VSCodeThemeSuite {
    static let settings = #"""
    {
      // the person's profile
      "workbench.colorTheme": "Light Modern",
      "chat.fontFamily": "Atkinson Hyperlegible",
      "remote.url": "https://example.com/a", /* a URL keeps its slashes */
      "workbench.colorCustomizations": {
        "editor.background": "#D2C8B1",
        "sideBar.background": "#D6CDB8",
        "sideBar.foreground": "#22201C",
        "[Light Modern]": { "sideBar.foreground": "#111111" },
      },
    }
    """#

    static let suite = TestSuite("Like my VS Code", [

        TestCase("VS Code's settings read, comments and trailing commas and all") { t in
            let parsed = VSCodeTheme.parse(settings)
            t.expectEqual(parsed?["workbench.colorTheme"] as? String, "Light Modern")
            t.expectEqual(parsed?["remote.url"] as? String, "https://example.com/a", "a // inside a string is not a comment")
        },

        TestCase("The chat's background and text: the profile first, the theme's scoped colours over its general ones") { t in
            let parsed = VSCodeTheme.parse(settings) ?? [:]
            let colors = VSCodeTheme.colors(settings: parsed, themeName: "Light Modern",
                                            themeColors: ["sideBar.background": "#FFFFFF", "terminal.ansiRed": "#cd3131"])
            t.expectEqual(colors?.background, "#d6cdb8", "the profile's, over the theme's white")
            t.expectEqual(colors?.text, "#111111", "scoped to the theme in use")
            t.expectEqual(colors?.isDark, false)
            t.expectNil(colors?.ansi, "a palette only when all sixteen are said")
        },

        TestCase("The sixteen terminal colours when they are all there; the theme's own when not customised") { t in
            var theme: [String: String] = [:]
            for (i, key) in VSCodeTheme.ansiKeys.enumerated() { theme[key] = String(format: "#%02x0000", i * 10) }
            let colors = VSCodeTheme.colors(settings: [:], themeName: nil, themeColors: theme.merging(["editor.background": "#1e1e1eff"]) { a, _ in a })
            t.expectEqual(colors?.ansi?.count, 16)
            t.expectEqual(colors?.background, "#1e1e1e", "alpha dropped, editor as the last resort")
            t.expectEqual(colors?.isDark, true)
            t.expectNil(VSCodeTheme.colors(settings: [:], themeName: nil, themeColors: [:]), "nothing to read")
        },

        TestCase("The chat font's fixed-width sibling, when this Mac has one") { t in
            t.expectEqual(VSCodeTheme.monoSibling(of: "Atkinson Hyperlegible", among: ["Menlo", "Atkinson Hyperlegible Mono"]),
                          "Atkinson Hyperlegible Mono")
            t.expectEqual(VSCodeTheme.monoSibling(of: "'JetBrains Mono', monospace", among: ["JetBrains Mono"]), "JetBrains Mono")
            t.expectNil(VSCodeTheme.monoSibling(of: "Atkinson Hyperlegible", among: ["Menlo"]))
            t.expectNil(VSCodeTheme.monoSibling(of: nil, among: ["Menlo"]))
        },

        TestCase("A live theme from the colours: the chat's background on the card, a shade darker behind") { t in
            let theme = VSCodeTheme.liveTheme(VSCodeTheme.Colors(background: "#d6cdb8", text: "#22201c", ansi: nil, isDark: false))
            t.expectEqual(theme.id, LiveTheme.fromVSCodeId)
            t.expectEqual(theme.card, "#d6cdb8")
            t.expect(VSCodeTheme.luminance(theme.backdropBottom) < VSCodeTheme.luminance(theme.card), "darker behind")
        },
    ])
}

/// A fixed-width font is one that measures so (D145).
enum FixedPitchSuite {
    static let suite = TestSuite("Fixed-width fonts, measured", [

        TestCase("Every probe character at one width is fixed-width; any difference is not") { t in
            t.expect(FixedPitch.isUniform([7.2, 7.2, 7.2, 7.2]), "a monospace font")
            t.expect(!FixedPitch.isUniform([3.1, 11.4, 10.2, 3.0]), "a proportional one")
            t.expect(!FixedPitch.isUniform([0, 0, 0, 0]), "a font that draws nothing")
            t.expect(!FixedPitch.isUniform([7.2, 7.2]), "not every probe measured")
        },
    ])
}

/// Letters set tighter (D146).
enum LetterSpacingSuite {
    static let suite = TestSuite("Letter spacing", [
        TestCase("Held between 85% and 100%, 100% by default") { t in
            t.expectEqual(LiveAppearance(theme: LiveTheme.named(nil), fontSize: 13).letterSpacing, 1)
            t.expectEqual(LiveAppearance(theme: LiveTheme.named(nil), fontSize: 13, letterSpacing: 0.5).letterSpacing, 0.85)
            t.expectEqual(LiveAppearance(theme: LiveTheme.named(nil), fontSize: 13, letterSpacing: 1.4).letterSpacing, 1)
            t.expectEqual(LiveAppearance(theme: LiveTheme.named(nil), fontSize: 13, letterSpacing: 0.9).letterSpacing, 0.9)
        },
    ])
}

/// The live view's chat (D147): a transcript followed as it grows.
enum LiveChatFeedSuite {
    static let suite = TestSuite("The live view's chat", [

        TestCase("A line counts once its newline has arrived, in whatever pieces it came") { t in
            var buffer = TranscriptLineBuffer(keep: 10)
            t.expect(!buffer.append(Data(#"{"type":"user","#.utf8)), "half a line is not one")
            t.expect(buffer.append(Data((#""x":1}"# + "\n").utf8)), "its end completes it")
            t.expectEqual(buffer.lines, [#"{"type":"user","x":1}"#])
            buffer.append(Data("\n   \n".utf8))
            t.expectEqual(buffer.lines.count, 1, "blank lines are not lines")
        },

        TestCase("A character split between two reads arrives whole") { t in
            var buffer = TranscriptLineBuffer(keep: 10)
            let bytes = Array("città\n".utf8)
            buffer.append(Data(bytes[..<4]))
            buffer.append(Data(bytes[4...]))
            t.expectEqual(buffer.lines, ["città"])
        },

        TestCase("Only the last lines are kept: a long transcript's end is what a chat shows") { t in
            var buffer = TranscriptLineBuffer(keep: 3)
            buffer.append(Data((1...6).map { "line \($0)\n" }.joined().utf8))
            t.expectEqual(buffer.lines, ["line 4", "line 5", "line 6"])
        },

        TestCase("Another machine's transcript: where Claude Code writes it, followed under sh, quoted") { t in
            let path = LiveChatSource.remotePath(sessionId: "s1", cwd: "/home/dev/my web")
            t.expectEqual(path, ".claude/projects/-home-dev-my-web/s1.jsonl")
            let command = LiveChatSource.remoteFollow(path: path)
            t.expect(command.hasPrefix("sh -c '"), command)
            t.expect(command.contains("tail -n \(LiveChatSource.keptLines) -F"), command)
            t.expect(command.contains("cat >/dev/null; kill $p"), "tail ends when the connection's input closes: \(command)")
            t.expect(command.contains(#"'\''.claude/projects/-home-dev-my-web/s1.jsonl'\''"#), command)
        },
    ])
}

/// «Custom» (D148): two colours picked, the rest following them.
enum CustomThemeSuite {
    static let suite = TestSuite("The custom look", [
        TestCase("The card is the background picked, the window a shade darker, dark or light by it") { t in
            let light = LiveTheme.custom(background: "#f4efe6", text: "#22201c")
            t.expectEqual(light.card, "#f4efe6")
            t.expectEqual(light.text, "#22201c")
            t.expect(!light.isDark, "a light background")
            t.expect(VSCodeTheme.luminance(light.backdropBottom) < VSCodeTheme.luminance(light.card), "darker behind")
            t.expect(LiveTheme.custom(background: "#101418", text: "#e0e0e0").isDark, "a dark one")
            t.expectNil(light.ansi, "the terminal keeps its own sixteen")
        },
    ])
}
