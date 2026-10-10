import Foundation
import LampBoardCore
import TestKit

/// How the Hub writes to a session (D154): the mod where it takes commands, the
/// box or the pane where it does not, never over a dialog, and read only when
/// there is no known way in.
enum HubWriteSuite {

    private static func situation(commands: Bool = false, box: Bool = false, paste: Bool = false,
                                  busy: Bool = false, asking: Bool = false,
                                  presence: HubWrite.Presence = .empty) -> HubWrite.Situation {
        HubWrite.Situation(commands: commands, box: box, paste: paste, busy: busy, asking: asking, presence: presence)
    }

    static let suite = TestSuite("The Hub's way into a session", [

        TestCase("A session whose mod takes commands is written to through the mod, in every mode but steering a turn") { t in
            for mode in [HubWrite.Mode.interrupt, .queue] {
                t.expectEqual(HubWrite.route(mode, in: situation(commands: true, box: true, busy: true)), .mod, mode.rawValue)
            }
            t.expectEqual(HubWrite.route(.steer, in: situation(commands: true, box: true)), .mod, "nothing running: steering is queueing")
        },

        TestCase("Steering a running turn goes through the box, which takes a message into it") { t in
            t.expectEqual(HubWrite.route(.steer, in: situation(commands: true, box: true, busy: true)), .box)
            t.expectEqual(HubWrite.route(.steer, in: situation(box: true, busy: true)), .box)
        },

        TestCase("Nothing is put through the box or the pane while a dialog waits") { t in
            t.expectEqual(HubWrite.route(.queue, in: situation(box: true, paste: true, asking: true)), .none)
            t.expectEqual(HubWrite.route(.steer, in: situation(box: true, busy: true, asking: true)), .none)
            t.expectEqual(HubWrite.route(.queue, in: situation(commands: true, asking: true)), .mod, "the mod waits for the dialog by itself")
        },

        TestCase("Without the mod: the box, then the pane when nothing runs, then read only") { t in
            t.expectEqual(HubWrite.route(.queue, in: situation(box: true, paste: true)), .box)
            t.expectEqual(HubWrite.route(.queue, in: situation(paste: true)), .paste)
            t.expectEqual(HubWrite.route(.queue, in: situation(paste: true, busy: true)), .none, "a line pasted mid-turn is lost or answers a prompt")
            t.expectEqual(HubWrite.route(.queue, in: situation()), .none)
        },

        TestCase("A message goes as the person's words, stopping the turn only when asked to") { t in
            t.expectEqual(HubWrite.submitArgs(text: "go", mode: .interrupt), ["text": "go", "asUser": "true", "mode": "interrupt"])
            t.expectEqual(HubWrite.submitArgs(text: "go", mode: .queue)["mode"], "queue")
            t.expectEqual(HubWrite.submitArgs(text: "go", mode: .steer)["mode"], "queue", "steering through the mod is queueing")
        },

        TestCase("Nothing to send, or too much, is not sent") { t in
            t.expectNil(HubWrite.sendable("   \n "))
            t.expectNil(HubWrite.sendable(String(repeating: "x", count: HubWrite.maxBytes + 1)))
            t.expectEqual(HubWrite.sendable("  run the tests \n"), "run the tests")
        },
        TestCase("The live bubble shows the last lines of a reply, each cut from the left") { t in
            let reply = (1...50).map { "line \($0)" }.joined(separator: "\n")
            t.expectEqual(HubWrite.tail(of: reply, lines: 3), "line 48\nline 49\nline 50")
            let long = String(repeating: "a", count: 300) + "END"
            let cut = HubWrite.tail(of: long, lines: 8)
            t.expectEqual(cut.count, 200, "a long line is cut to a bubble's width")
            t.expect(cut.hasPrefix("…") && cut.hasSuffix("END"), "from the left, so the newest words stay")
            t.expectEqual(HubWrite.tail(of: "", lines: 8), "")
            let huge = String(repeating: "word ", count: 200_000)
            t.expect(HubWrite.tail(of: huge, lines: 8).count <= 200, "a huge reply costs no more than a short one")
        },

        TestCase("A draft in the session's own box asks before sending, and is never pasted into (E19)") { t in
            let mod = HubWrite.verdict(.queue, in: situation(commands: true, presence: .draft))
            t.expectEqual(mod.route, .mod)
            t.expect(mod.confirm, "the person is typing there: ask first")
            t.expect(!HubWrite.verdict(.queue, in: situation(commands: true)).confirm, "an empty box: no question")
            t.expectEqual(HubWrite.verdict(.queue, in: situation(paste: true, presence: .draft)).route, .none,
                          "a paste would join the draft")
        },

        TestCase("A box LampBoard cannot see gets a band, and messages only queue (E21)") { t in
            let unseen = HubWrite.verdict(.interrupt, in: situation(commands: true, busy: true, presence: .unseen))
            t.expectEqual(unseen.mode, .queue, "no stopping a turn in a window we cannot see")
            t.expectEqual(unseen.route, .mod)
            t.expect(unseen.band != nil, "the band says why")
            t.expectNil(HubWrite.verdict(.interrupt, in: situation(commands: true)).band)
            t.expectEqual(HubWrite.verdict(.interrupt, in: situation(commands: true)).mode, .interrupt)
        },

        TestCase("Nothing goes over a dialog except through the mod, which waits for it (E20)") { t in
            t.expectEqual(HubWrite.verdict(.queue, in: situation(box: true, paste: true, asking: true)).route, .none)
            t.expectEqual(HubWrite.verdict(.queue, in: situation(commands: true, asking: true)).route, .mod)
        },

        TestCase("Where a session's box is: the mod's surface, else how it was started") { t in
            t.expectEqual(HubWrite.presence(surface: "terminal", entrypoint: "cli", draft: true), .draft)
            t.expectEqual(HubWrite.presence(surface: "terminal", entrypoint: "cli", draft: nil), .empty)
            t.expectEqual(HubWrite.presence(surface: "vscode", entrypoint: "claude-vscode", draft: false), .unseen)
            t.expectEqual(HubWrite.presence(surface: "desktop", entrypoint: nil, draft: nil), .unseen)
            t.expectEqual(HubWrite.presence(surface: nil, entrypoint: "claude-vscode", draft: nil), .unseen)
            t.expectEqual(HubWrite.presence(surface: nil, entrypoint: "claude-desktop", draft: nil), .unseen)
            t.expectEqual(HubWrite.presence(surface: nil, entrypoint: "cli", draft: nil), .empty)
        },

        TestCase("A message has arrived once the transcript holds one more of it than when it was sent (E22)") { t in
            let before = ["run the tests", "and the lint"]
            t.expect(!HubWrite.arrived("run the tests", before: before, now: before), "the old one is not a receipt")
            t.expect(HubWrite.arrived("run the tests", before: before, now: before + ["run  the tests\n"]),
                     "spaces and the end of line do not matter")
            t.expect(!HubWrite.arrived("deploy", before: before, now: before + ["something else"]))
        },
    ])
}
