import Foundation
import LampBoardCore
import TestKit

/// LampMaster's hands (hub-terminale R10–R11): what it may do to the other
/// sessions, and what the person is asked about.
enum LampMasterHandsSuite {

    static func facts(_ surface: LampMasterHands.Surface, _ status: SessionStatus, lampMaster: Bool = false) -> LampMasterHands.Facts {
        LampMasterHands.Facts(id: "4b138f7d-67ab-4d4c-9396-77adaed0f851", name: "web", project: "web", host: nil,
                              surface: surface, status: status, minutes: 3, isLampMaster: lampMaster)
    }

    static func call(_ line: String) -> [String: Any] {
        let answer = LampMasterHands.respond(to: line, version: "t") { tool, arguments in
            ("ran \(tool.rawValue) \(arguments["session"] as? String ?? "")", false)
        }
        return (try? JSONSerialization.jsonObject(with: Data((answer ?? "{}").utf8)) as? [String: Any]) ?? [:]
    }

    static let suite = TestSuite("LampMaster's hands", [

        TestCase("It writes only into a session in tmux, at rest, with an empty prompt") { t in
            t.expectEqual(LampMasterHands.canSend(facts(.tmux, .ready), promptEmpty: true), .send)
            for refused in [facts(.vscode, .ready), facts(.app, .ready), facts(.background, .ready), facts(.other, .ready),
                            facts(.tmux, .working), facts(.tmux, .waiting), facts(.tmux, .awaiting), facts(.tmux, .ready, lampMaster: true)] {
                guard case .refuse = LampMasterHands.canSend(refused, promptEmpty: true) else {
                    return t.fail("\(refused.surface) \(refused.status) should be refused")
                }
            }
            guard case .refuse = LampMasterHands.canSend(facts(.tmux, .ready), promptEmpty: false) else { return t.fail("typed prompt") }
            guard case .refuse = LampMasterHands.canSend(facts(.tmux, .ready), promptEmpty: nil) else { return t.fail("unread prompt") }
        },

        TestCase("It stops only a working session it has a terminal into") { t in
            t.expectEqual(LampMasterHands.canStop(facts(.tmux, .working)), .send)
            guard case .refuse = LampMasterHands.canStop(facts(.tmux, .ready)) else { return t.fail("at rest") }
            guard case .refuse = LampMasterHands.canStop(facts(.vscode, .working)) else { return t.fail("VS Code") }
        },

        TestCase("A session is read as its last messages, the person's and its own; a cut line is left out") { t in
            let tail = """
            ","message":{"role":"user","content":"cut in half"}}
            {"type":"user","uuid":"u1","timestamp":"2026-10-11T09:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"Fix the build"}}
            {"type":"assistant","uuid":"a1","timestamp":"2026-10-11T09:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Fixed: a missing import."}]}}
            """
            let digest = LampMasterHands.digest(tail: tail, messages: 5)
            t.expectEqual(digest, "[person] Fix the build\n\n[session] Fixed: a missing import.")
            t.expectEqual(LampMasterHands.digest(tail: tail, messages: 1), "[session] Fixed: a missing import.")
            t.expectEqual(LampMasterHands.digest(tail: "", messages: 3), "Nothing said yet in this session.")
        },

        TestCase("What it sends says where it comes from, without control characters, bounded") { t in
            let framed = LampMasterHands.framed("Run the tests\u{1b}[2J\u{202e} please\nand report.")
            t.expect(framed.hasPrefix("[From LampMaster, at the person's request] "), framed)
            t.expect(!framed.contains("\u{1b}") && !framed.contains("\u{202e}"), "no escape, no direction override")
            t.expect(framed.contains("\n"), "a line break stays: it is pasted as one")
            t.expect(LampMasterHands.framed(String(repeating: "x", count: 9_000)).count < 4_100, "bounded")
        },

        TestCase("A session is named by its id or a unique start of it, and LampMaster is left out of the list") { t in
            let a = facts(.tmux, .ready)
            let b = LampMasterHands.Facts(id: "4b13ffff-0000-4000-8000-000000000000", name: "api", project: "api", host: "box",
                                          surface: .vscode, status: .working, minutes: 1)
            let me = facts(.tmux, .working, lampMaster: true)
            t.expectNil(LampMasterHands.find("4b13", in: [a, b]), "ambiguous")
            t.expectEqual(LampMasterHands.find("4B138F", in: [a, b])?.name, "web")
            t.expectNil(LampMasterHands.find("4b", in: [a]), "too short")
            let list = LampMasterHands.list([a, b, me])
            t.expectEqual(list.split(separator: "\n").count, 2, list)
            t.expect(list.contains("api on box · vscode · working 1 min ago · read only"), list)
            t.expect(list.contains("web on this Mac · tmux · ready 3 min ago · writable"), list)
        },

        TestCase("An empty prompt is told by the cursor, whatever grey suggestion follows it") { t in
            let screen = ["─────", "❯ Try \"edit <file> to...\"", "─────"]
            t.expect(PromptLine.isEmpty(lines: screen, cursorX: 2, cursorY: 1), "the cursor right after the mark")
            t.expect(!PromptLine.isEmpty(lines: ["❯ fix the build"], cursorX: 15, cursorY: 0), "typed text moves it on")
            t.expect(!PromptLine.isEmpty(lines: ["❯ first", "  second"], cursorX: 8, cursorY: 1), "a second line")
            t.expect(!PromptLine.isEmpty(lines: ["Do you want to proceed?"], cursorX: 2, cursorY: 0), "not the prompt")
            t.expect(!PromptLine.isEmpty(lines: [], cursorX: 0, cursorY: 3), "no screen")
            let look = HandsScript.parseLook("2 1 2.1.296\n─────\n❯ \n─────")
            t.expectEqual(look?.x, 2)
            t.expectEqual(look?.command, "2.1.296")
            t.expect(look.map { PromptLine.isEmpty(lines: $0.lines, cursorX: $0.x, cursorY: $0.y) } == true, "parsed back, empty")
            t.expect(HandsScript.isShell("-zsh") && HandsScript.isShell("bash") && !HandsScript.isShell("2.1.296") && !HandsScript.isShell("claude"),
                     "Claude Code gone, its shell left: nothing is pasted into a shell")
        },

        TestCase("The text goes by standard input, as one bracketed paste, then Enter; every target quoted") { t in
            let send = HandsScript.send(target: "=web's:0.0", cursorX: 2, cursorY: 30, buffer: "a1b2") ?? ""
            t.expect(send.contains("= '2 30' ] || { echo 'the prompt changed'; exit 3; }"),
                     "the cursor checked again in the same script, just before the paste: \(send)")
            t.expect(send.contains("tmux load-buffer -b lampmaster-a1b2 - && tmux paste-buffer -p -d -b lampmaster-a1b2"), send)
            t.expect(send.contains(#"-t '=web'\''s:0.0'"#), send)
            t.expect(send.hasSuffix("Enter"), send)
            t.expect(send.hasPrefix(#"export PATH="$PATH:/opt/homebrew/bin"#), "Homebrew's tmux over ssh")
            t.expectNil(HandsScript.send(target: "=web:0.0", cursorX: 2, cursorY: 3, buffer: "x; rm"), "a buffer name is plain")
            t.expect(HandsScript.stop(target: "=web:0.0").hasSuffix("Escape"), "Esc")
            let look = HandsScript.look(target: "=web:0.0")
            t.expect(look.contains("tmux -u display-message") && look.contains("tmux -u capture-pane"),
                     "UTF-8 asked for: without a locale tmux writes ❯ as _ \(look)")
        },

        TestCase("Its server lists seven tools; what reads is marked as data, what acts is asked about") { t in
            let list = call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            t.expectEqual(tools, ["sessions", "read_session", "search_conversations", "send_to_session", "stop_session",
                                  "start_session", "open_in_hub"])
            let read = call(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_session","arguments":{"session":"4b13"}}}"#)
            let text = (((read["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            t.expect(text.hasPrefix(LampMasterMCP.dataNotice), text)
            t.expectEqual(LampMasterHands.Tool.allCases.filter(\.acts).map(\.rawValue),
                          ["send_to_session", "stop_session", "start_session", "open_in_hub"])
        },

        TestCase("Its folder: the server only there, only the tools that read allowed ahead") { t in
            let mcp = String(decoding: LampMasterHome.mcpConfig(executable: "/Applications/LampBoard.app/x", port: 9900, defaultPort: 9876,
                                                                key: "k3y"), as: UTF8.self)
            t.expect(mcp.contains(#""args" : ["#) && mcp.contains(#""--hands""#) && mcp.contains(#""9900""#), mcp)
            t.expect(mcp.contains(#""LAMPBOARD_HANDS_KEY" : "k3y""#), "the key of this start, for its server alone: \(mcp)")
            t.expect(!mcp.contains("LAMPBOARD_HOME"), "the account's home unless LampBoard runs against another")
            let fake = String(decoding: LampMasterHome.mcpConfig(executable: "/x", port: 9876, defaultPort: 9876, key: "k",
                                                                 home: "/tmp/fake"), as: UTF8.self)
            t.expect(fake.contains(#""LAMPBOARD_HOME" : "\/tmp\/fake""#) || fake.contains(#""LAMPBOARD_HOME" : "/tmp/fake""#), fake)
            let settings = (try? JSONSerialization.jsonObject(with: LampMasterHome.settings()) as? [String: Any]) ?? [:]
            t.expectEqual(settings["enabledMcpjsonServers"] as? [String], ["lampboard"])
            let permissions = settings["permissions"] as? [String: Any]
            t.expectEqual(permissions?["allow"] as? [String], ["mcp__lampboard__sessions", "mcp__lampboard__read_session",
                                                               "mcp__lampboard__search_conversations"])
            t.expectEqual(permissions?["ask"] as? [String], ["mcp__lampboard__send_to_session", "mcp__lampboard__stop_session",
                                                             "mcp__lampboard__start_session", "mcp__lampboard__open_in_hub"],
                          "every action asked about, whatever the mode")
            t.expectEqual(permissions?["defaultMode"] as? String, "default")
            t.expectEqual(permissions?["disableBypassPermissionsMode"] as? String, "disable")
        },

        TestCase("A start says how: in tmux unless told otherwise, and in Settings' permission mode unless one is named") { t in
            t.expectEqual(LampMasterHands.startOptions([:]).keepsRunning, true)
            t.expectNil(LampMasterHands.startOptions([:]).permissions, "Settings decide")
            let temporary = LampMasterHands.startOptions(["keepsRunning": false, "permissions": "bypass"])
            t.expectEqual(temporary.keepsRunning, false)
            t.expectEqual(temporary.permissions, .bypass)
            t.expectEqual(LampMasterHands.startOptions(["permissions": "allowBypass"]).permissions, .allowBypass)
            t.expectNil(LampMasterHands.startOptions(["permissions": "--rm"]).permissions, "an unknown mode is no flag")
            let schema = LampMasterHands.Tool.startSession.inputSchema["properties"] as? [String: Any] ?? [:]
            t.expectEqual(Set(schema.keys), ["folder", "host", "resume", "keepsRunning", "permissions"])
            t.expectEqual((schema["permissions"] as? [String: Any])?["enum"] as? [String], ["ask", "allowBypass", "bypass"])
            t.expect(LampMasterHands.Tool.startSession.description.contains("bypass"), "the modes are told")
        },

        TestCase("A search says where each conversation ran, so it can be taken up there") { t in
            let at = Date(timeIntervalSince1970: 1_800_000_000)
            let found = [
                LampMasterHands.Found(sessionId: "4b138f7d-67ab-4d4c-9396-77adaed0f851", title: "Pricing page", folder: "/home/dev/site",
                                      host: "box", lastAt: at, snippet: "the «pricing» table"),
                LampMasterHands.Found(sessionId: "9ffa24f0-6fa8-4ebc-88fe-551d610cba17", title: nil, folder: "/Users/dev/app",
                                      host: nil, lastAt: nil, snippet: "pricing\nagain"),
            ]
            let text = LampMasterHands.searchResult(found, query: "pricing", day: { _ in "1 Jan" })
            t.expect(text.contains("Pricing page · /home/dev/site on box · 1 Jan · id 4b138f7d-67ab-4d4c-9396-77adaed0f851"), text)
            t.expect(text.contains("untitled · /Users/dev/app on this Mac"), text)
            t.expect(text.contains("start_session"), "how to take one up: \(text)")
            t.expect(LampMasterHands.searchResult([], query: "pricing", day: { _ in "" }).contains("No conversation"), "none")
            t.expect(!LampMasterHands.Tool.searchConversations.acts, "a search reads")
        },

        TestCase("Its instructions say who it is, and how it finds and opens a past conversation") { t in
            let text = LampMasterHome.instructions
            t.expect(text.contains("You are LampMaster"), text)
            t.expect(text.contains("search_conversations") && text.contains("start_session"), text)
            t.expect(text.contains("keepsRunning") && text.contains("permissions"), text)
        },
    ])
}
