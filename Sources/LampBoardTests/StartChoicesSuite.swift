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
    ])
}
