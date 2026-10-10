import Foundation
import LampBoardCore
import TestKit

/// How the Hub writes to a session (D154): the mod where it takes commands, the
/// box or the pane where it does not, never over a dialog, and read only when
/// there is no known way in.
enum HubWriteSuite {

    private static func situation(commands: Bool = false, box: Bool = false, paste: Bool = false,
                                  busy: Bool = false, asking: Bool = false) -> HubWrite.Situation {
        HubWrite.Situation(commands: commands, box: box, paste: paste, busy: busy, asking: asking)
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
    ])
}
