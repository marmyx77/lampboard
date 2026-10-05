import LampBoardCore
import Foundation
import TestKit

/// LampMaster's test bench (D5): a new prompt or model replayed on the frames
/// the rounds were given, its suggestions set against the old ones and against
/// what the person did with them. A lost accepted card is a regression; an
/// ignored one gone is an improvement.
enum LampMasterBenchSuite {

    static func suggestion(_ key: String, _ kind: LampMasterAdvice.Suggestion.Kind = .stalled) -> LampMasterAdvice.Suggestion {
        LampMasterAdvice.Suggestion(kind: kind, sessions: ["aaaaaaaa"], text: "text \(key)", evidence: "e",
                                    action: .init(kind: .none), confidence: 0.8, key: key)
    }

    static let suite = TestSuite("LampMaster: the test bench", [

        TestCase("A saved round reads back as its frame and the answer it got") { t in
            let saved = LampMasterBench.saved("{\"sessions\":[]}\n{\"type\":\"result\"}\n", at: Date(timeIntervalSince1970: 1))
            t.expectEqual(saved?.frame, "{\"sessions\":[]}")
            t.expectEqual(saved?.output, "{\"type\":\"result\"}")
            t.expectNil(LampMasterBench.saved("only a frame\n", at: Date()), "no answer, nothing to compare")
        },

        TestCase("Kept, lost and new by key; a lost accepted card is a regression, an ignored one gone a gain") { t in
            let comparison = LampMasterBench.compare(
                old: [suggestion("taken"), suggestion("passed over"), suggestion("both")],
                new: [suggestion("both"), suggestion("fresh", .cross)],
                outcomes: ["taken": .accepted, "passed over": .ignored, "both": .accepted]
            )
            t.expectEqual(comparison.kept.map(\.key), ["both"])
            t.expectEqual(comparison.lost.map(\.key), ["passed over", "taken"])
            t.expectEqual(comparison.added.map(\.key), ["fresh"])
            t.expectEqual(comparison.regressions, 1, "the accepted one lost")
            t.expectEqual(comparison.gains, 1, "the ignored one gone")
        },

        TestCase("The report names the regressions first, in words a person decides on") { t in
            let comparison = LampMasterBench.compare(old: [suggestion("taken")], new: [], outcomes: ["taken": .accepted])
            let report = LampMasterBench.report([(Date(timeIntervalSince1970: 1_800_000_000), comparison)], model: "sonnet")
            t.expect(report.hasPrefix("Bench: 1 round replayed with sonnet. 1 accepted suggestion lost, 0 ignored gone, 0 new."), report)
            t.expect(report.contains("lost (accepted): text taken"), report)
        },
    ])
}
