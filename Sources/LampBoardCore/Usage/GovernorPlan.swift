import Foundation

/// The governor (§5.2, G3): which sessions run one model lower until the window
/// resets, chosen by the person in the panel and applied by the companion mod.
///
/// Only one step down, only on a click, only until the reset: after it each
/// session is back on its own model without anybody remembering to undo it. The
/// session in focus is never lowered — it is the one the person is working in.
public struct GovernorPlan: Codable, Sendable, Equatable {

    public struct Lowered: Codable, Sendable, Equatable {
        public let model: String
        public let until: Date
    }

    public let sessions: [String: Lowered]

    public init(sessions: [String: Lowered] = [:]) {
        self.sessions = sessions
    }

    /// The model a session runs on now, when it is lowered.
    public func model(for sessionId: String, now: Date) -> String? {
        guard let lowered = sessions[sessionId], lowered.until > now else { return nil }
        return lowered.model
    }

    public func lowering(_ sessionId: String, to model: String, until: Date, focused: String? = nil) -> GovernorPlan {
        guard sessionId != focused else { return self }
        var next = sessions
        next[sessionId] = Lowered(model: model, until: until)
        return GovernorPlan(sessions: next)
    }

    public func releasing(_ sessionId: String) -> GovernorPlan {
        var next = sessions
        next[sessionId] = nil
        return GovernorPlan(sessions: next)
    }

    public func pruned(now: Date) -> GovernorPlan {
        GovernorPlan(sessions: sessions.filter { $0.value.until > now })
    }

    /// One step down, by family: the version is the one this release knows to
    /// be current, since a session told "sonnet" gets that family's newest.
    /// A session on a million-token window is not offered: the model a step down
    /// may have a smaller one, and its conversation would no longer fit.
    public static func lowered(from model: String) -> String? {
        guard !model.contains("[") else { return nil }
        let bare = model
        if bare.hasPrefix("claude-opus") { return "claude-sonnet-5-5" }
        if bare.hasPrefix("claude-sonnet") { return "claude-haiku-4-5" }
        return nil
    }

    public static func encode(_ plan: GovernorPlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(plan)
    }

    public static func decode(_ data: Data) throws -> GovernorPlan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GovernorPlan.self, from: data)
    }
}

/// What travels between the mod and the panel about a session's model (G3).
/// Proven both ways with the permission key, like the decision board: a model is
/// spend, and a listener that is not the panel must not choose it.
public enum GovernorExchange {

    public static func proofMessage(nonce: String, session: String) -> String {
        "governor:\(nonce):\(session)"
    }

    public static func provenSession(_ body: Data, nonce: String?, proof: String?, key: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["v"] as? Int == 1,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let nonce, let proof,
              PermissionGate.proves(proof, PermissionGate.mac(key: key, message: proofMessage(nonce: nonce, session: session)),
                                    nonce: nonce)
        else { return nil }
        return session
    }

    /// `model <id> <signature>`, or `model - <signature>` for the session's own.
    public static func answer(model: String?, nonce: String, key: String) -> String {
        let said = model ?? "-"
        return "model \(said) " + PermissionGate.mac(key: key, message: "governed:\(nonce):\(said)")
    }
}
