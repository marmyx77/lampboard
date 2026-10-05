import LampBoardCore
import Foundation
import TestKit

/// The governor (§5.2, G3): a session lowered one model until the window resets,
/// only on the person's click, the session in focus protected.
enum GovernorSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static let suite = TestSuite("Governor", [

        TestCase("One step down: Opus to Sonnet, Sonnet to Haiku, Haiku nowhere") { t in
            t.expectEqual(GovernorPlan.lowered(from: "claude-opus-5-5"), "claude-sonnet-5-5")
            t.expectNil(GovernorPlan.lowered(from: "claude-opus-5-5[1m]"), "a million-token window may not fit a step down")
            t.expectEqual(GovernorPlan.lowered(from: "claude-sonnet-5-5"), "claude-haiku-4-5")
            t.expectNil(GovernorPlan.lowered(from: "claude-haiku-4-5"))
            t.expectNil(GovernorPlan.lowered(from: "gpt-5"), "not ours to lower")
        },

        TestCase("A session lowered until the reset, and back to its own after it or when taken off") { t in
            let plan = GovernorPlan().lowering("s1", to: "claude-sonnet-5-5", until: t0.addingTimeInterval(3600))
            t.expectEqual(plan.model(for: "s1", now: t0), "claude-sonnet-5-5")
            t.expectNil(plan.model(for: "s1", now: t0.addingTimeInterval(3601)), "the window reset: its own model again")
            t.expectNil(plan.model(for: "s2", now: t0))
            t.expectNil(plan.releasing("s1").model(for: "s1", now: t0))
            t.expectNil(GovernorPlan().lowering("s1", to: "claude-sonnet-5-5", until: t0.addingTimeInterval(3600), focused: "s1")
                .model(for: "s1", now: t0), "the session in focus keeps its model")
        },

        TestCase("The mod is heard only proven for its own session, and believes only a signed model") { t in
            let key = String(repeating: "ab", count: 16), nonce = "0123456789abcdef0123"
            let session = "e2e0d0d0-0000-4000-8000-0000000000aa"
            let body = Data(#"{"v":1,"session":"\#(session)"}"#.utf8)
            let proof = PermissionGate.mac(key: key, message: GovernorExchange.proofMessage(nonce: nonce, session: session))
            t.expectEqual(GovernorExchange.provenSession(body, nonce: nonce, proof: proof, key: key), session)
            t.expectNil(GovernorExchange.provenSession(body, nonce: nonce, proof: nil, key: key))
            let answer = GovernorExchange.answer(model: "claude-sonnet-5-5", nonce: nonce, key: key)
            t.expectEqual(answer, "model claude-sonnet-5-5 " + PermissionGate.mac(key: key, message: "governed:\(nonce):claude-sonnet-5-5"))
            t.expect(GovernorExchange.answer(model: nil, nonce: nonce, key: key).hasPrefix("model - "), "none: its own model")
        },

        TestCase("The plan survives a round trip through its file, the expired ones dropped") { t in
            let plan = GovernorPlan()
                .lowering("s1", to: "claude-sonnet-5-5", until: t0.addingTimeInterval(3600))
                .lowering("s2", to: "claude-haiku-4-5", until: t0.addingTimeInterval(-1))
            guard let data = try? GovernorPlan.encode(plan.pruned(now: t0)) else { return t.fail("not encoded") }
            let back = try? GovernorPlan.decode(data)
            t.expectEqual(back?.model(for: "s1", now: t0), "claude-sonnet-5-5")
            t.expectNil(back?.model(for: "s2", now: t0.addingTimeInterval(-10)), "an expired entry is not kept")
        },
    ])
}
