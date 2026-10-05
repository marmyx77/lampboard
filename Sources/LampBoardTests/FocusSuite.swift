import LampBoardCore
import Foundation
import TestKit

/// A session in the foreground (§5.3, G1): while one is, the others' notifications
/// wait, and come back in one summary when the focus is taken off.
enum FocusSuite {

    static let suite = TestSuite("Focus", [

        TestCase("Without a focus everything passes; with one, only the focused session") { t in
            t.expect(FocusHold().admits("s1"), "no focus, no hold")
            let held = FocusHold(focused: "s1")
            t.expect(held.admits("s1"), "the session in focus")
            t.expect(!held.admits("s2"), "another waits")
        },

        TestCase("What waits is kept by kind, once per session and kind, the newest name winning") { t in
            let hold = FocusHold(focused: "s1")
                .holding(.waiting, sessionId: "s2", name: "api")
                .holding(.waiting, sessionId: "s2", name: "api")
                .holding(.finished, sessionId: "s3", name: "docs-site")
                .holding(.failed, sessionId: "s4", name: "billing")
                .holding(.finished, sessionId: "s1", name: "events")
            t.expectEqual(hold.held.count, 3, "the focused one is never held, a repeat counts once")
        },

        TestCase("Taken off, the focus says in one line what waited, the most urgent first") { t in
            let hold = FocusHold(focused: "s1")
                .holding(.finished, sessionId: "s3", name: "docs-site")
                .holding(.waiting, sessionId: "s2", name: "api")
                .holding(.failed, sessionId: "s4", name: "billing")
                .holding(.finished, sessionId: "s5", name: "search")
            t.expectEqual(hold.summary(),
                          "While you were focused: 1 waiting for you (api), 1 failed (billing), 2 answers (docs-site, search).")
            t.expectNil(FocusHold(focused: "s1").summary(), "nothing waited, nothing to say")
            t.expect(hold.released().held.isEmpty && hold.released().focused == nil, "released, empty")
            t.expectEqual(hold.keeping { $0.sessionId != "s2" }.summary(),
                          "While you were focused: 1 failed (billing), 2 answers (docs-site, search).",
                          "what was answered meanwhile is not said")
        },
    ])
}
