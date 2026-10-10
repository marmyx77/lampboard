import Foundation
import LampBoardCore
import TestKit

/// The Hub's command bar (D157): a slash line is a command only when the
/// session has it, the mode is read from the footer and reached by Shift+Tab in
/// its cycle, a model change warns over a warm cache, an attachment gets a name
/// of its own in the project's folder for them.
enum HubBarSuite {

    static let suite = TestSuite("The Hub's command bar", [

        TestCase("A slash line is a command only when the session has one by that name") { t in
            let known: Set<String> = ["compact", "plan", "remote-control"]
            t.expectEqual(HubBar.slash("/compact keep the API notes", known: known)?.name, "compact")
            t.expectEqual(HubBar.slash("/compact keep the API notes", known: known)?.args, "keep the API notes")
            t.expectEqual(HubBar.slash("  /plan  ", known: known)?.args, "")
            t.expectNil(HubBar.slash("/etc/hosts is odd", known: known), "a path is words")
            t.expectNil(HubBar.slash("please /compact", known: known), "only at the start")
            t.expectNil(HubBar.slash("/compact\nand then this", known: known), "one line only")
        },

        TestCase("The footer's label says the mode; nothing shown is the manual one") { t in
            t.expectEqual(HubBar.mode(footer: "plan mode on"), .plan)
            t.expectEqual(HubBar.mode(footer: "auto mode on"), .auto)
            t.expectEqual(HubBar.mode(footer: "accept edits on"), .acceptEdits)
            t.expectEqual(HubBar.mode(footer: ""), .manual)
            t.expectEqual(HubBar.mode(footer: "bypass permissions on"), .bypass)
        },

        TestCase("Shift+Tab goes round Plan, Auto, Manual, Accept edits") { t in
            t.expectEqual(HubBar.presses(from: .plan, to: .auto), 1)
            t.expectEqual(HubBar.presses(from: .auto, to: .plan), 3)
            t.expectEqual(HubBar.presses(from: .acceptEdits, to: .plan), 1)
            t.expectEqual(HubBar.presses(from: .manual, to: .manual), 0)
            t.expectNil(HubBar.presses(from: .bypass, to: .plan), "a mode out of the cycle is not pressed into")
        },

        TestCase("A model changed over a warm cache warns first") { t in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let warm = ContextReading(tokens: 90_000, model: "claude-opus-5-5", window: 200_000, confidence: .reported,
                                      at: now.addingTimeInterval(-60), cacheLifetime: 300, cacheAt: now.addingTimeInterval(-60))
            let cold = ContextReading(tokens: 90_000, model: "claude-opus-5-5", window: 200_000, confidence: .reported,
                                      at: now.addingTimeInterval(-600), cacheLifetime: 300, cacheAt: now.addingTimeInterval(-600))
            t.expect(HubBar.cacheWarm(warm, now: now), "written a minute ago, five minutes of life")
            t.expect(!HubBar.cacheWarm(cold, now: now), "gone cold")
            t.expect(!HubBar.cacheWarm(nil, now: now), "nothing known: no warning")
        },

        TestCase("An attachment gets a plain name of its own in the project's attachments") { t in
            t.expectEqual(HubBar.attachmentName("screen shot (1).png", taken: []), "screen-shot-1.png")
            t.expectEqual(HubBar.attachmentName("a.png", taken: ["a.png"]), "a-2.png")
            t.expectEqual(HubBar.attachmentName("a.png", taken: ["a.png", "a-2.png"]), "a-3.png")
            t.expectEqual(HubBar.attachmentName("../../etc/passwd", taken: []), "passwd")
            t.expectEqual(HubBar.attachmentName(".env", taken: []), "env")
            t.expectEqual(HubBar.citation(of: "a-2.png"), "@.lampboard/allegati/a-2.png")
        },
    ])
}
