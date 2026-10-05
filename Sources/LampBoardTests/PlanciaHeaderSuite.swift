import LampBoardCore
import Foundation
import TestKit

/// The Plancia's header (UX §5, R2): what a person wants to know of the session
/// in focus before acting on it, on one line under its name.
enum PlanciaHeaderSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(host: String? = nil, origin: SessionOrigin = .terminal, harness: Harness = .claudeCode,
                        context: ContextReading? = nil, cost: Double? = nil) -> SessionState {
        SessionState(id: "s1", status: .idle, workspace: Workspace(path: "/home/dev/events", host: host),
                     updatedAt: t0, statusSince: t0, harness: harness, origin: origin, context: context, costUSD: cost)
    }

    static let suite = TestSuite("The Plancia's header", [

        TestCase("Machine, surface and agent, model, context, cost — in that order") { t in
            let reading = ContextReading(tokens: 142_300, model: "claude-opus-5-5", window: 200_000, confidence: .exact, at: t0)
            t.expectEqual(PlanciaHeader.facts(session(context: reading, cost: 0.4249)),
                          "this Mac · terminal · Claude Code · Opus 5.5 · 142k of 200k · $0.42")
        },

        TestCase("What is not known is left out, never guessed") { t in
            t.expectEqual(PlanciaHeader.facts(session(host: "node", origin: .editor)), "node · editor · Claude Code")
            let codex = ContextReading(tokens: 1_260_000, model: "gpt-5.5-codex", window: nil, confidence: .exact, at: t0)
            t.expectEqual(PlanciaHeader.facts(session(harness: .codex, context: codex)), "this Mac · terminal · Codex · gpt-5.5-codex · 1.3M")
        },

        TestCase("Claude's model ids read as their names") { t in
            t.expectEqual(PlanciaHeader.model("claude-sonnet-5-5"), "Sonnet 5.5")
            t.expectEqual(PlanciaHeader.model("claude-haiku-4-5-20251001"), "Haiku 4.5")
            t.expectEqual(PlanciaHeader.model("claude-opus-5-5[1m]"), "Opus 5.5")
            t.expectEqual(PlanciaHeader.model("claude-fable-5-1"), "Fable 5.1")
            t.expectEqual(PlanciaHeader.model("some-other-model"), "some-other-model", "anything else as it came")
        },
    ])
}
