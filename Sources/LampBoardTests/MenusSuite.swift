import LampBoardCore
import Foundation
import TestKit

/// Three short menus (U3): the panel's ⋯ with seven entries, a row's with eight
/// and two submenus, the lamp's with the ways of keeping quiet. Everything else
/// lives in Settings, under the same name.
enum MenusSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func titles(_ entries: [MenuEntry]) -> [String] {
        entries.compactMap { entry in
            switch entry {
            case .item(_, let title, _, _, _): return title
            case .submenu(let title, _): return title + " ▸"
            case .heading(let title): return title
            case .divider: return nil
            }
        }
    }

    private static func submenu(_ title: String, in entries: [MenuEntry]) -> [MenuEntry] {
        for entry in entries { if case .submenu(title, let inner) = entry { return inner } }
        return []
    }

    private static let quiet = PanelMenuState(onlyWaiting: false, mutedUntil: nil, isAway: false, hiddenCount: 0)

    private static func row(remote: Bool = false, status: SessionStatus = .ready, repository: String? = "web",
                            pinned: [String] = [], attach: String? = nil, offer: String? = nil,
                            newConversation: Bool = true) -> RowMenuState {
        RowMenuState(isRemote: remote, compact: false, alias: nil, folder: "web", status: status,
                     isHidden: false, isCalm: false, isMuted: false, isFocused: false, notificationsEnabled: true,
                     hostsNewConversation: newConversation, repository: repository, pinned: pinned,
                     attachCommand: attach, modelOffer: offer)
    }

    static let suite = TestSuite("Menus", [

        TestCase("The panel's ⋯: eight entries, Settings with ⌘, before the way out") { t in
            let entries = Menus.panel(quiet, time: { _ in "14:30" })
            t.expectEqual(titles(entries), [
                "Open the conversations…", "What the lights mean…", "What LampBoard can do…", "Show only what's waiting",
                "Mute alerts for an hour", "I'm away", "Settings…", "Quit LampBoard",
            ])
            t.expect(entries.contains { if case .item(.settings, _, _, _, ",") = $0 { return true }; return false },
                     "Settings carries ⌘,")
        },

        TestCase("The ⋯ says what is on, and offers the hidden projects only when there are some") { t in
            let state = PanelMenuState(onlyWaiting: true, mutedUntil: t0, isAway: true, hiddenCount: 3)
            let entries = Menus.panel(state, time: { _ in "14:30" })
            t.expect(titles(entries).contains("Resume alerts (muted until 14:30)"), "muted: the way back, with the time")
            t.expect(titles(entries).contains("Show 3 hidden projects"), "hidden: how many")
            t.expect(entries.contains { if case .item(.onlyWaiting, _, true, _, _) = $0 { return true }; return false },
                     "a switch on is checked")
            t.expect(entries.contains { if case .item(.away, _, true, _, _) = $0 { return true }; return false },
                     "away is checked")
        },

        TestCase("A row's menu: eight entries, Quiet and More holding the rest") { t in
            let entries = Menus.row(row(status: .awaiting, pinned: ["UTC everywhere"],
                                        offer: "Use Sonnet until the window resets"))
            t.expectEqual(titles(entries), [
                "Open", "Read the conversation", "Open in Session view", "New conversation here",
                "Rename…", "Hide", "Quiet ▸", "More ▸",
            ])
            t.expectEqual(titles(submenu("Quiet", in: entries)), ["Don't alert me", "Don't blink", "Focus on this session"])
            let more = titles(submenu("More", in: entries))
            t.expectEqual(more, [
                "New conversation in LampBoard", "Open without marking as read", "Move up", "Move down", "Show in Finder",
                "Add a project rule for “web”…", "Project rules (1) ▸", "Use Sonnet until the window resets",
            ])
        },

        TestCase("A background session opens here, in the live view, beside its terminal command (D130)") { t in
            let entries = Menus.row(row(attach: "claude attach 4b1"))
            t.expectEqual(Array(titles(entries).prefix(2)), ["Open", "Open here"])
            t.expect(entries.contains { if case .item(.openHere, _, _, _, _) = $0 { return true }; return false }, "its command")
            t.expect(titles(submenu("More", in: entries)).contains("Copy “claude attach 4b1”"), "the command is still copied")
            t.expect(!titles(Menus.row(row())).contains("Open here"), "an interactive session never opens here: two writers")
            t.expect(!titles(Menus.row(row(remote: true, attach: "claude attach 4b1"))).contains("Open here"),
                     "a background session on another machine is not attached to from this one")
        },

        TestCase("A row on another machine offers nothing that would need this Mac's files or editor") { t in
            let titles = titles(Menus.row(row(remote: true, repository: nil, newConversation: false)))
            t.expect(!titles.contains("Read the conversation"), "the transcript is over there")
            t.expect(!titles.contains("Open in Session view"), "same")
            t.expect(!titles.contains("New conversation here"), "no local editor for it")
            let more = Self.titles(submenu("More", in: Menus.row(row(remote: true, repository: nil, newConversation: false))))
            t.expect(!more.contains("Show in Finder"), "the folder is on that machine")
            t.expect(!more.contains("New conversation in LampBoard"), "a live session starts on this Mac only")
        },

        TestCase("Don't blink only where something blinks; Mark as unread only on a row at rest") { t in
            t.expect(!titles(submenu("Quiet", in: Menus.row(row(status: .ready)))).contains("Don't blink"), "nothing blinks")
            t.expect(titles(submenu("More", in: Menus.row(row(status: .idle)))).contains("Mark as unread"), "at rest")
        },

        TestCase("The lamp: what waits, the panel, the two ways of being quiet, Settings, the way out") { t in
            let entries = Menus.lamp(LampMenuState(wanting: 2, working: 3, home: .menuBar, mutedUntil: nil, isAway: false))
            t.expectEqual(titles(entries), [
                "2 waiting · 3 working", "Open the panel", "Open the conversations…", "Mute alerts for an hour",
                "I'm away", "Put the panel in its own window", "Settings…", "Quit LampBoard",
            ])
            let floating = Menus.lamp(LampMenuState(wanting: 0, working: 0, home: .floating, mutedUntil: nil, isAway: false))
            t.expect(titles(floating).contains("Put the panel in the menu bar"), "the other home")
            t.expect(titles(floating).contains("Nothing waiting · nothing at work"), "zeros said in words")
        },
    ])
}
