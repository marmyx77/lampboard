import LampBoardCore
import Foundation
import TestKit

/// Three short menus (U3, D165): the panel's ⋯, a row's with the Hub first and
/// two submenus, the lamp's with the ways of keeping quiet. Everything else
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
                            newConversation: Bool = true, move: Bool = false, elsewhere: String? = nil) -> RowMenuState {
        RowMenuState(isRemote: remote, compact: false, alias: nil, folder: "web", status: status,
                     isHidden: false, isCalm: false, isMuted: false, isFocused: false, notificationsEnabled: true,
                     hostsNewConversation: newConversation, repository: repository, pinned: pinned,
                     attachCommand: attach, modelOffer: offer, canMoveHere: move, elsewhere: elsewhere)
    }

    static let suite = TestSuite("Menus", [

        TestCase("The panel's ⋯: nine entries, New session with ⌘N, Settings with ⌘, before the way out") { t in
            let entries = Menus.panel(quiet, time: { _ in "14:30" })
            t.expect(entries.contains { if case .item(.newSession, _, _, _, "n") = $0 { return true }; return false }, "⌘N")
            t.expectEqual(titles(entries), [
                "Open the Hub", "New session…", "What the lights mean…", "What LampBoard can do…", "Show only what's waiting",
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

        TestCase("A row's menu: the Hub first, where else it lives, what starts in its folder; Quiet and More hold the rest") { t in
            let entries = Menus.row(row(status: .awaiting, pinned: ["UTC everywhere"],
                                        offer: "Use Sonnet until the window resets", elsewhere: "VS Code"))
            t.expectEqual(titles(entries), [
                "Open in the Hub", "Show in VS Code", "Start a new session in this folder", "New conversation in VS Code",
                "Rename…", "Hide", "Quiet ▸", "More ▸",
            ])
            t.expect(entries.first.map { if case .item(.sessionView, _, _, _, _) = $0 { return true }; return false } == true,
                     "Open in the Hub is the Hub's command")
            t.expectEqual(titles(submenu("Quiet", in: entries)), ["Don't alert me", "Don't blink", "Focus on this session"])
            let more = titles(submenu("More", in: entries))
            t.expectEqual(more, [
                "Open without marking as read", "Move up", "Move down", "Show in Finder",
                "Add a project rule for “web”…", "Project rules (1) ▸", "Use Sonnet until the window resets",
            ])
        },

        TestCase("No entry leads to a window 2.1 no longer has, and none says the Hub in another name (D165)") { t in
            for state in [row(), row(remote: true), row(attach: "claude attach 4b1"), row(move: true, elsewhere: "VS Code")] {
                let all = titles(Menus.row(state)) + titles(submenu("More", in: Menus.row(state)))
                for gone in ["Open here", "Read the conversation", "Open in Session view", "New conversation in LampBoard",
                             "New conversation here", "Open"] {
                    t.expect(!all.contains(gone), "«\(gone)» is gone: \(all)")
                }
            }
            t.expect(titles(submenu("More", in: Menus.row(row(attach: "claude attach 4b1")))).contains("Copy “claude attach 4b1”"),
                     "the command is still copied")
            t.expect(!titles(Menus.row(row())).contains { $0.hasPrefix("Show in") }, "a session in LampBoard's terminal shows nowhere else")
        },

        TestCase("A conversation in VS Code offers to move to LampBoard, right under its place (D135)") { t in
            let entries = Menus.row(row(move: true, elsewhere: "VS Code"))
            t.expectEqual(Array(titles(entries).prefix(3)), ["Open in the Hub", "Show in VS Code", "Move to LampBoard…"])
            t.expect(!Menus.row(row()).contains { if case .item(.moveHere, _, _, _, _) = $0 { return true }; return false },
                     "and only then")
        },

        TestCase("A row on another machine opens in the Hub too, and offers nothing that needs this Mac's files or editor") { t in
            let entries = Menus.row(row(remote: true, repository: nil, newConversation: false))
            t.expectEqual(titles(entries).first, "Open in the Hub")
            t.expect(!titles(entries).contains("New conversation in VS Code"), "no local editor for it")
            t.expect(titles(entries).contains("Start a new session in this folder"), "it starts inside tmux there (D133)")
            t.expect(!titles(submenu("More", in: entries)).contains("Show in Finder"), "the folder is on that machine")
        },

        TestCase("Don't blink only where something blinks; Mark as unread only on a row at rest") { t in
            t.expect(!titles(submenu("Quiet", in: Menus.row(row(status: .ready)))).contains("Don't blink"), "nothing blinks")
            t.expect(titles(submenu("More", in: Menus.row(row(status: .idle)))).contains("Mark as unread"), "at rest")
        },

        TestCase("The lamp: what waits, the panel, the two ways of being quiet, Settings, the way out") { t in
            let entries = Menus.lamp(LampMenuState(wanting: 2, working: 3, home: .menuBar, mutedUntil: nil, isAway: false))
            t.expectEqual(titles(entries), [
                "2 waiting · 3 working", "Open the panel", "Open the Hub", "Mute alerts for an hour",
                "I'm away", "Put the panel in its own window", "Settings…", "Quit LampBoard",
            ])
            let floating = Menus.lamp(LampMenuState(wanting: 0, working: 0, home: .floating, mutedUntil: nil, isAway: false))
            t.expect(titles(floating).contains("Put the panel in the menu bar"), "the other home")
            t.expect(titles(floating).contains("Nothing waiting · nothing at work"), "zeros said in words")
        },
    ])
}
