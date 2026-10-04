import LampBoardCore
import Foundation
import TestKit

/// What the round answers, and what the validator lets through.
enum LampMasterAdviceSuite {

    typealias S = LampMasterAdvice.Suggestion
    typealias F = LampMasterFixtures

    static let frame = #"{"sessions":[{"id":"9ffa24f0","lastAnswer":"The build DocsSite-8241f9e is ready but not installed: write «install» when you want"},{"id":"ba409f17","context":"872k/1000k"}]}"#
    static let ids: Set<String> = ["9ffa24f0", "ba409f17"]

    static func suggestion(
        kind: S.Kind = .stalled, sessions: [String] = ["9ffa24f0"],
        evidence: String = #"The answer says "The build DocsSite-8241f9e is ready but not installed"."#,
        target: String? = nil, confidence: Double = 0.8, key: String = "build waiting"
    ) -> S {
        S(kind: kind, sessions: sessions, text: "The build waits for you.", evidence: evidence,
          action: .init(kind: target == nil ? .reply : .ask, target: target), confidence: confidence, key: key)
    }

    static func screen(_ suggestions: [S], shownAt: [String: Date] = [:], muted: Set<S.Kind> = []) -> LampMasterValidator.Verdict {
        LampMasterValidator.screen(LampMasterAdvice(suggestions: suggestions), frame: frame, ids: ids,
                                   shownAt: shownAt, muted: muted, now: F.at(0))
    }

    static let suite = TestSuite("LampMaster: advice and its validator", [

        TestCase("A suggestion with known sessions and a real quote is shown") { t in
            t.expectEqual(screen([suggestion()]).shown.count, 1)
        },

        TestCase("Curly quotes, guillemets and case do not break a real quote") { t in
            let curly = suggestion(evidence: "It wrote “write «INSTALL» when you want” at the end.")
            t.expectEqual(screen([curly]).shown.count, 1)
        },

        TestCase("Evidence that is not in the frame is dropped") { t in
            let invented = suggestion(evidence: #"It said "the deployment to production failed twice"."#)
            t.expectEqual(screen([invented]).rejected.map(\.1), [.noEvidence])
        },

        TestCase("A quote too short to prove anything is dropped") { t in
            t.expectEqual(screen([suggestion(evidence: #"It said "install"."#)]).rejected.map(\.1), [.noEvidence])
        },

        TestCase("A session or a target that is not in the frame is dropped") { t in
            t.expectEqual(screen([suggestion(sessions: ["deadbeef"])]).rejected.map(\.1), [.unknownSession])
            t.expectEqual(screen([suggestion(target: "deadbeef")]).rejected.map(\.1), [.unknownSession])
            t.expectEqual(screen([suggestion(sessions: [])]).rejected.map(\.1), [.unknownSession])
        },

        TestCase("Shown in the last day, muted, or unsure: not shown") { t in
            t.expectEqual(screen([suggestion()], shownAt: ["build waiting": F.at(-60)]).rejected.map(\.1), [.shownRecently])
            t.expectEqual(screen([suggestion()], shownAt: ["build waiting": F.at(-25 * 60)]).shown.count, 1)
            t.expectEqual(screen([suggestion()], muted: [.stalled]).rejected.map(\.1), [.muted])
            t.expectEqual(screen([suggestion(confidence: 0.4)]).rejected.map(\.1), [.lowConfidence])
        },

        TestCase("No more than three a round") { t in
            let four = (0..<4).map { suggestion(key: "k\($0)") }
            let verdict = screen(four)
            t.expectEqual(verdict.shown.count, 3)
            t.expectEqual(verdict.rejected.map(\.1), [.overLimit])
        },

        TestCase("The result of claude -p is read through structured_output") { t in
            let raw = #"{"type":"result","structured_output":{"notebook":"watching the build","suggestions":[{"kind":"closable","sessions":["ba409f17"],"text":"t","evidence":"e","action":{"kind":"open"},"confidence":0.7,"key":"k"}]}}"#
            let advice = LampMasterAdvice.decode(Data(raw.utf8))
            t.expectEqual(advice?.suggestions.first?.kind, .closable)
            t.expectEqual(advice?.notebook, "watching the build")
        },

        TestCase("A malformed answer is nil, never half an answer") { t in
            t.expectNil(LampMasterAdvice.decode(Data("not json".utf8)))
            t.expectNil(LampMasterAdvice.decode(Data(#"{"structured_output":{"suggestions":[{"kind":"gossip"}]}}"#.utf8)))
        },

        TestCase("The prompt names the language and fences the frame") { t in
            t.expect(LampMasterPrompt.system(language: "Italian").contains("in Italian"), "the language is named")
            t.expect(LampMasterPrompt.message(frame: "{}").contains("<frame>\n{}\n</frame>"), "the frame is fenced")
            t.expectNotNil(try? JSONSerialization.jsonObject(with: Data(LampMasterPrompt.schema.utf8)))
        },
    ])
}
