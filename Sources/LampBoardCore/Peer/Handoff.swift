import Foundation

/// The baton (5.4): one session writes what another needs to carry on — asked
/// as a side question (D82), so it costs the first no turn — and the text waits
/// in the second's composer for the person to read, change and send (D85).
public enum Handoff {

    /// Its name in the bar: `/handoff @from @to`.
    public static let command = "handoff"

    /// What the first session is asked. Within a side question's size.
    public static let question = """
        Another Claude Code session is taking over from you, or depends on your work. Write the handoff it \
        will read before it starts: what you understood, what you decided and why, what is left to do, and \
        the files you touched. Plain text, at most thirty lines, no secret values.
        """

    /// A handoff a session wrote itself, with `/handoff <name>` (T2): the mod
    /// posts it to `POST /handoff`, and the panel proposes it to that session.
    public struct Request: Sendable, Equatable {
        public let session: String
        public let to: String
        public let text: String

        public init(session: String, to: String, text: String) {
            self.session = session
            self.to = to
            self.text = text
        }
    }

    /// A name, not a sentence; and the mod's own cap on what it posts.
    static let maxName = 80
    static let maxText = 4000

    /// The request, or `nil` when it does not read or is not proven: version 1,
    /// a session of Claude Code's shape, a name, words within the mod's cap —
    /// counted as it counts them, by code point — and the mod's HMAC with the
    /// permission key, which no hook carries (D80), over the fields as sent.
    /// The token alone could put words in a composer under any session's name.
    public static func request(_ body: Data, nonce: String?, proof: String?, key: String) -> Request? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["v"] as? Int == 1,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let rawTo = object["to"] as? String, let rawText = object["text"] as? String,
              let nonce, let proof,
              PermissionGate.proves(proof, PermissionGate.mac(key: key, message: "handoff:\(nonce):\(session):\(rawTo):\(rawText)"),
                                    nonce: nonce)
        else { return nil }
        let to = String(rawTo.trimmed.drop { $0 == "@" }), text = rawText.trimmed
        guard !to.isEmpty, to.count <= maxName, !text.isEmpty, text.unicodeScalars.count <= maxText else { return nil }
        return Request(session: session, to: to, text: text)
    }

    /// The message proposed to the second session: whose it is, then the text.
    public static func brief(from source: String, text: String) -> String {
        "Handoff from \(LampMasterLookup.clean(source, to: LampMasterLookup.titleLength)), through LampBoard:\n\n\(text.trimmed)"
    }
}
