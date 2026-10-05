import Foundation

/// A question to a live session without disturbing it (D82): put into its box
/// as one line the companion mod can prove came from this panel, then the
/// question. The mod takes the message before the session sees it, answers it
/// with `$.model.fork` over the session's own conversation — no turn, the
/// prefix read from cache — and posts the reply back as an `answer` report.
///
/// Measured on the test Mac with a probe mod (Claude Code 2.1.289, 5 October
/// 2026): a message taken in `session.receive` leaves nothing in the
/// transcript; the fork answered from the conversation in about a second and a
/// half, idle or mid-turn; and a message without the line passed untouched.
public enum PeerAsk {

    /// What a mod that can answer says in its `start` report.
    public static let feature = "ask"
    /// A side question, not a brief. Counted in UTF-16 units, as the mod's
    /// JavaScript counts them: a question within the bound here is within it there.
    public static let maxQuestion = 2000
    /// How long the panel waits for the answer.
    public static let answerWithin: TimeInterval = 60

    static let head = "LampBoard asks without disturbing"

    /// The message, or `nil` when there is nothing to ask or too much. The
    /// proof is the permission key's (D80): a line any process could write is
    /// answered only when it carries it.
    public static func message(question: String, nonce: String, session: String, key: String) -> String? {
        let asked = question.trimmed
        guard !asked.isEmpty, asked.utf16.count <= maxQuestion else { return nil }
        let proof = PermissionGate.mac(key: key, message: "fork:\(nonce):\(session):\(asked)")
        return "\(head) [v1 \(nonce) \(proof)]:\n\(asked)"
    }
}
