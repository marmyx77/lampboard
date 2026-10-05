import LampBoardCore
import Foundation
import TestKit

/// The bar at the top of the panel: what was typed, and what it finds (UX §2).
enum CommandBarSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(_ name: String, _ status: SessionStatus = .idle, title: String? = nil,
                            message: String? = nil) -> ColumnRow {
        let session = SessionState(id: "id-\(name)", status: status, workspace: Workspace(path: "/home/dev/\(name)"),
                                   lastMessage: message, updatedAt: t0, statusSince: t0, origin: .terminal, title: title)
        return ColumnRow(id: "row-\(name)", workspace: session.workspace, sessions: [session])
    }

    private static let rows = [
        row("docs-site", .ready, message: "Guide rewritten: 42 pages."),
        row("api", .awaiting), row("api-gateway"), row("mobile-client", .failed), row("events", .working),
    ]

    private static func titles(_ query: String, lampMaster: Bool = true) -> [String] {
        CommandBar.results(for: CommandBar.parse(query), rows: rows, now: t0, lampMasterEnabled: lampMaster).map(\.title)
    }

    static let suite = TestSuite("The command bar", [

        TestCase("What was typed is read as text, a mention, a question or a command") { t in
            t.expectEqual(CommandBar.parse(""), .empty)
            t.expectEqual(CommandBar.parse("  "), .empty)
            t.expectEqual(CommandBar.parse("docs"), .text("docs"))
            t.expectEqual(CommandBar.parse("@api how is it going"), .mention(name: "api", message: "how is it going"))
            t.expectEqual(CommandBar.parse("?who renamed the slots"), .ask("who renamed the slots"))
            t.expectEqual(CommandBar.parse("/settings now"), .command(name: "settings", argument: "now"))
        },

        TestCase("Names first: exact, then from the start, then from a word, then anywhere") { t in
            t.expectEqual(Array(titles("api").prefix(2)), ["api", "api-gateway"])
            t.expectEqual(titles("gate").first, "api-gateway", "from a word inside the name")
            t.expectEqual(titles("client").first, "mobile-client")
        },

        TestCase("A session is found by what it says, too, after the names") { t in
            t.expectEqual(titles("guide").first, "docs-site", "its answer mentions the guide")
        },

        TestCase("Empty, the bar lists what needs you, the most urgent first") { t in
            t.expectEqual(titles(""), ["api", "docs-site", "mobile-client"])
        },

        TestCase("Actions answer to their words, after the sessions") { t in
            let found = CommandBar.results(for: CommandBar.parse("settings"), rows: rows, now: t0, lampMasterEnabled: true)
            t.expectEqual(found.first?.action, .settings)
            let command = CommandBar.results(for: CommandBar.parse("/up"), rows: rows, now: t0, lampMasterEnabled: true)
            t.expectEqual(command.map(\.action), [.checkForUpdates], "a command names only actions")
        },

        TestCase("@ names only sessions") { t in
            let found = CommandBar.results(for: CommandBar.parse("@ev hi"), rows: rows, now: t0, lampMasterEnabled: true)
            t.expectEqual(found.map(\.sessionId), ["id-events"])
        },

        TestCase("@ with words after the name sends them, once the switch is on") { t in
            let on = CommandBar.results(for: CommandBar.parse("@api run the tests"), rows: rows, now: t0,
                                        lampMasterEnabled: true, sendingEnabled: true)
            t.expectEqual(on.first?.kind, .send)
            t.expectEqual(on.first?.sessionId, "id-api", "the exact name first")
            t.expectEqual(on.first?.title, "Send to api: run the tests")
            t.expectEqual(on.map(\.kind), [.send, .send], "api and api-gateway, each a send")
            let off = CommandBar.results(for: CommandBar.parse("@api run the tests"), rows: rows, now: t0, lampMasterEnabled: true)
            t.expectEqual(off.first?.kind, .send)
            t.expectEqual(off.first?.detail, "Turn on \"Let the panel answer your sessions\" in the panel menu first")
            let bare = CommandBar.results(for: CommandBar.parse("@api"), rows: rows, now: t0, lampMasterEnabled: true, sendingEnabled: true)
            t.expectEqual(bare.first?.kind, .session, "a name alone finds the session")
        },

        TestCase("A session on another Mac is said, never sent to from here") { t in
            let away = SessionState(id: "id-node", status: .idle, workspace: Workspace(path: "/home/dev/nodeapp", host: "node"),
                                    updatedAt: t0, statusSince: t0, origin: .terminal)
            let row = ColumnRow(id: "row-node", workspace: away.workspace, sessions: [away])
            let found = CommandBar.results(for: CommandBar.parse("@nodeapp deploy"), rows: [row], now: t0,
                                           lampMasterEnabled: true, sendingEnabled: true)
            t.expectEqual(found.first?.kind, .send)
            t.expectNil(found.first?.sessionId, "nothing to send to")
            t.expectEqual(found.first?.detail, "On another Mac: the panel cannot write there yet")
        },

        TestCase("? goes to LampMaster, or says it is off") { t in
            let on = CommandBar.results(for: .ask("who renamed slots"), rows: rows, now: t0, lampMasterEnabled: true)
            t.expectEqual(on.first?.kind, .ask)
            t.expectEqual(on.first?.title, "Ask LampMaster: who renamed slots")
            let off = CommandBar.results(for: .ask("who renamed slots"), rows: rows, now: t0, lampMasterEnabled: false)
            t.expectEqual(off.first?.detail, "LampMaster is switched off in Settings")
        },

        TestCase("A session's title reaches the bar as one clean line") { t in
            let named = row("raw", title: "Fix\u{202E}nigol\nthe login")
            let found = CommandBar.results(for: .text("fix"), rows: [named], now: t0, lampMasterEnabled: true)
            t.expectEqual(found.first?.title, "Fix nigol the login")
        },

        TestCase("The shortcut from anywhere is off unless one is chosen, and never ⌘K alone") { t in
            t.expectEqual(BarShortcut.stored(nil), .off)
            t.expectEqual(BarShortcut.stored("commandK"), .off, "an unknown value is off, not a guess")
            t.expectNil(BarShortcut.off.keyCode)
            t.expectEqual(BarShortcut.stored("optionCommandK").keyCode, 40)
            for shortcut in BarShortcut.allCases where shortcut != .off {
                t.expect(shortcut.carbonModifiers & 0x1800 != 0, "\(shortcut.label) carries ⌥ or ⌃, so VS Code keeps ⌘K")
            }
        },

        TestCase("The selection moves within the results and stops at the ends") { t in
            t.expectEqual(CommandBar.move(0, by: -1, count: 3), 0)
            t.expectEqual(CommandBar.move(0, by: 1, count: 3), 1)
            t.expectEqual(CommandBar.move(2, by: 1, count: 3), 2)
            t.expectEqual(CommandBar.move(5, by: 0, count: 2), 1, "kept in range when the list shrinks")
            t.expectEqual(CommandBar.move(0, by: 1, count: 0), 0)
        },
    ])
}
