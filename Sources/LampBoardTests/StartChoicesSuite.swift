import LampBoardCore
import Foundation
import TestKit

/// What the person chooses at one start (D185, D186): skipping permissions for
/// that session only, and a fork of a conversation taken up from there.
enum StartChoicesSuite {

    static let suite = TestSuite("Choices made at a start", [

        // A fork is a new conversation that starts as a copy of another (D186):
        // the id is LampBoard's, so its row and terminal are known before it
        // speaks, as for a new one; the original is left as it was.
        TestCase("A fork resumes its original into a new id LampBoard chose, in the mode chosen") { t in
            let from = "6f1c2d3e-4a5b-4c6d-8e7f-0123456789ab"
            let id = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
            t.expectEqual(NewSession.claudeLine(.fork(from: from, sessionId: id)),
                          "claude --resume \(from) --fork-session --session-id \(id)")
            t.expectEqual(NewSession.claudeLine(.fork(from: from.uppercased(), sessionId: id, permissions: .bypass)),
                          "claude --resume \(from) --fork-session --session-id \(id) --dangerously-skip-permissions")
            t.expectEqual(NewSession.Start.fork(from: from, sessionId: id).sessionId, id, "the row is the fork's")
            t.expectEqual(NewSession.Start.fork(from: from, sessionId: id).with(.allowBypass),
                          .fork(from: from, sessionId: id, permissions: .allowBypass))
            t.expectNil(NewSession.claudeLine(.fork(from: "x; rm -rf ~", sessionId: id)), "only an id is written")
            t.expectNil(NewSession.claudeLine(.fork(from: id, sessionId: id)), "a fork of itself is no fork")
            let remote = NewSession.remoteCommand(folder: "/home/dev/web", name: "web", launch: "0123456789abcdef",
                                                  start: .fork(from: from, sessionId: id))
            t.expect(remote.contains("--resume \(from) --fork-session --session-id \(id) ||"), remote)
        },

        // Chosen at the start, by the person, in the window or the menu that starts
        // it (D185): ticked is bypass whatever Settings say; cleared is Settings'
        // mode, but never Settings' bypass — a box cleared means "ask me".
        TestCase("Skip permissions chosen at one start: ticked bypasses, cleared never does") { t in
            for settings in NewSession.Permissions.allCases {
                t.expectEqual(NewSession.Permissions.chosen(skipping: true, settings: settings), .bypass,
                              "ticked, with \(settings) in Settings")
            }
            t.expectEqual(NewSession.Permissions.chosen(skipping: false, settings: .ask), .ask, "cleared: Settings' ask")
            t.expectEqual(NewSession.Permissions.chosen(skipping: false, settings: .allowBypass), .allowBypass,
                          "cleared: Settings' bypass on Shift+Tab, which does not start in it")
            t.expectEqual(NewSession.Permissions.chosen(skipping: false, settings: .bypass), .ask,
                          "cleared with bypass in Settings: the person asked to be asked")
        },

        // Another account is its own configuration folder (D187): the line names
        // it under that machine's home, only where it exists, and a start whose
        // machine has no such folder stops and says so, rather than letting
        // Claude Code make an empty one and ask to sign in as if it were new.
        TestCase("Another account starts from its own folder, and only where that folder is") { t in
            let id = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
            let work = NewSession.Account(name: "work")
            t.expectEqual(work?.folder, ".claude-work")
            let line = NewSession.claudeLine(.new(sessionId: id, account: work))
            t.expectEqual(line, #"test -d "$HOME/.claude-work" && env CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude --session-id "# + id)
            t.expectEqual(NewSession.claudeLine(.new(sessionId: id)), "claude --session-id \(id)", "the default: no folder named")
            // The mode and the account survive each other.
            let both = NewSession.Start.resume(sessionId: id, account: work).with(.bypass)
            t.expectEqual(both.account, work, "a mode chosen keeps the account")
            t.expectEqual(both.with(account: nil).permissions, .bypass, "an account cleared keeps the mode")
            t.expect(NewSession.claudeLine(both)?.hasSuffix("claude --resume \(id) --dangerously-skip-permissions") == true,
                     NewSession.claudeLine(both) ?? "nil")
            let remote = NewSession.remoteCommand(folder: "/home/dev/web", name: "web", launch: "0123456789abcdef",
                                                  start: .new(sessionId: id, account: work))
            t.expect(remote.contains(#"test -d "$HOME/.claude-work" || { echo "There is no account work on this machine"#), remote)
            let local = NewSession.localCommand(folder: "/Users/dev/web", name: "web", launch: "0123456789abcdef",
                                                start: .new(sessionId: id, account: work)) ?? ""
            t.expect(local.contains("There is no account work on this Mac"), local)
            let plain = NewSession.localCommand(folder: "/Users/dev/web", name: "web", launch: "0123456789abcdef",
                                                start: .new(sessionId: id)) ?? ""
            t.expect(!plain.contains("account") && !plain.contains("\n\n"), "no account: the script as it was")
        },

        // Names reach a shell inside double quotes and a folder under the home:
        // only `.claude-` and lowercase letters, digits and inner dashes.
        TestCase("An account's folder is only ever .claude- and a plain name") { t in
            for bad in ["", "-x", "x-", "Work", "a b", "a\"b", "$(id)", "../x", "a/b", String(repeating: "a", count: 41)] {
                t.expectNil(NewSession.Account(name: bad), "refused: \(bad)")
            }
            t.expectNil(NewSession.Account(folder: ".claude"), "the default is no account")
            t.expectNil(NewSession.Account(folder: "claude-work"), "a folder that is not .claude-")
            t.expectEqual(NewSession.Account(name: "personale-2")?.name, "personale-2")
        },

        // Offered are the folders the script made, never ~/.claude-mem and the like.
        TestCase("The accounts offered are the folders that carry the script's marker") { t in
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: home) }
            for folder in [".claude", ".claude-mem", ".claude-work", ".claude-aworld", ".claude-Bad"] {
                try? FileManager.default.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
            }
            for folder in [".claude-work", ".claude-aworld", ".claude-Bad"] {
                FileManager.default.createFile(atPath: home + "/" + folder + "/" + NewSession.Account.marker, contents: Data())
            }
            t.expectEqual(NewSession.Account.found(in: home).map(\.name), ["aworld", "work"])
            t.expectEqual(NewSession.Account.found(in: home + "/nowhere"), [], "no home: no accounts")
        },

        // One shape wherever a menu starts a session (D188): before, a project
        // offered accounts but no skipping in one, and a row offered neither.
        TestCase("Every start menu has the same shape: its starts, skipping, each account and skipping there, the form") { t in
            let accounts = ["aworld-ai", "armellino"].compactMap { NewSession.Account(name: $0) }
            let entries = Menus.starts([.keepsRunning, .endsWhenClosed], accounts: accounts, on: "mini")
            t.expectEqual(titles(entries), [
                "Start a session that keeps running on mini", "Start a session that ends when closed on mini",
                "Skipping permissions ▸", "As aworld-ai ▸", "As armellino ▸", "New session here…",
            ])
            t.expectEqual(titles(submenu("As armellino", in: entries)), [
                "Start a session that keeps running on mini", "Start a session that ends when closed on mini", "Skipping permissions ▸",
            ])
            t.expectEqual(plans(in: submenu("Skipping permissions", in: submenu("As armellino", in: entries))), [
                StartPlan(kind: .new, keepsRunning: true, skipping: true, account: accounts[1]),
                StartPlan(kind: .new, keepsRunning: false, skipping: true, account: accounts[1]),
            ], "an account and skipping, together")
            t.expect(!titles(Menus.starts([.fork], accounts: [], form: false)).contains { $0.hasPrefix("As ") || $0 == "New session here…" },
                     "no accounts: no As; no form where it is not asked for")
        },

        TestCase("Each start does what its place in the menu says, and no two places do the same") { t in
            let accounts = ["a", "b"].compactMap { NewSession.Account(name: $0) }
            let offers: [StartOffer] = [.keepsRunning, .endsWhenClosed, .fork]
            var seen: [StartPlan] = []
            func walk(_ entries: [MenuEntry], skipping: Bool, account: NewSession.Account?) {
                for entry in entries {
                    switch entry {
                    case .item(.start(let plan), let title, _, _, _):
                        t.expect(plan.skipping == skipping && plan.account == account, "\(title): \(plan)")
                        t.expect(offers.contains { $0.title == title && $0.kind == plan.kind && $0.keepsRunning == plan.keepsRunning },
                                 "\(title) is what it starts")
                        seen.append(plan)
                    case .submenu("Skipping permissions", let inner): walk(inner, skipping: true, account: account)
                    case .submenu(let title, let inner): walk(inner, skipping: skipping, account: accounts.first { "As \($0.name)" == title })
                    default: break
                    }
                }
            }
            walk(Menus.starts(offers, accounts: accounts), skipping: false, account: nil)
            t.expectEqual(seen.count, offers.count * 2 * (1 + accounts.count), "every start, skipping or not, in every account")
            t.expectEqual(Set(seen).count, seen.count, "none twice")
            t.expectEqual(StartPlan(kind: .new, skipping: true).permissions, .bypass)
            t.expectNil(StartPlan(kind: .new).permissions, "not skipping is Settings' choice")
        },

        TestCase("A row's menu offers its starts in that same shape, with its fork and the accounts") { t in
            let accounts = [NewSession.Account(name: "work")!]
            let state = RowMenuState(isRemote: true, compact: false, alias: nil, folder: "web", status: .ready,
                                     isHidden: false, isCalm: false, isMuted: false, isFocused: false, notificationsEnabled: true,
                                     hostsNewConversation: false, repository: nil, pinned: [], attachCommand: nil,
                                     modelOffer: nil, canFork: true, accounts: accounts)
            let starts = Menus.starts([.keepsRunning, .endsWhenClosed, .fork], accounts: accounts)
            let row = Menus.row(state)
            let first = row.firstIndex(of: starts[0])
            t.expect(first.map { Array(row[$0..<min(row.count, $0 + starts.count)]) == starts } == true, "\(titles(row))")
            t.expectEqual(plans(in: submenu("As work", in: row)).map(\.kind), [.new, .new, .fork])
        },
    ])

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

    private static func plans(in entries: [MenuEntry]) -> [StartPlan] {
        entries.compactMap { if case .item(.start(let plan), _, _, _, _) = $0 { return plan }; return nil }
    }
}
