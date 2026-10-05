import Foundation

/// A session's question answered from the panel (D86): the `AskUserQuestion`
/// Claude puts to the person, put to the panel first by the companion mod,
/// which answers it with the person's choice or, unanswered in 55 seconds or
/// with the switch off, lets the session's own dialog ask it.
///
/// Measured on the test Mac (Q0, 5 October 2026): a mod's `tool.call` on
/// `AskUserQuestion` can return the answer itself — Claude Code recorded "User
/// answered Claude's questions: … → Blue" and the model read it — and may wait
/// on the panel over HTTP, 25 seconds held and 30 not; a `setTimeout` of 15
/// seconds, time the engine counts, lost the call to the dialog.
///
/// One question, one choice, two to four options: what a card can show. Any
/// other is the dialog's. The proof and the signature are the permission
/// key's (D80), under their own prefixes, so neither can stand for the other.
public enum QuestionGate {

    public static let tool = "AskUserQuestion"
    /// The panel's time to answer a question: less than a permission's. A
    /// `tool.call` hook is dropped between 25 and 30 seconds of waiting
    /// (measured: 25 held, 30 and 40 lost to the dialog), a `tool.check` only
    /// near a minute; 20 leaves the answer room to travel back.
    public static let answerWithin: TimeInterval = 20
    public static let optionLimit = 40
    static let questionLimit = 200

    /// `{"v":1,"session","id","question","header"?,"options":[…]}`, refused
    /// rather than guessed at: a refused question goes to the dialog.
    public static func decode(_ data: Data, at now: Date) -> PermissionGate.Request? {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == ModReport.version,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let call = object["id"] as? String, ModReport.isCallId(call),
              let question = (object["question"] as? String).flatMap({ clean($0, questionLimit) }),
              let raw = object["options"] as? [String], (2...4).contains(raw.count)
        else { return nil }
        let options = raw.compactMap { clean($0, optionLimit) }
        guard options.count == raw.count, Set(options).count == options.count else { return nil }
        return PermissionGate.Request(sessionId: session, callId: call, tool: tool, line: question, receivedAt: now, options: options)
    }

    public static func askMessage(nonce: String, session: String, call: String) -> String {
        "question:\(nonce):\(session):\(call)"
    }

    public static func isGenuine(key: String, nonce: String, proof: String, session: String, call: String) -> Bool {
        PermissionGate.proves(proof, PermissionGate.mac(key: key, message: askMessage(nonce: nonce, session: session, call: call)), nonce: nonce)
    }

    /// The choice as the mod checks it — `choose <index> <signature>` — or the
    /// dialog's turn, `ask <signature>`, as a permission's is.
    public static func signed(choice: Int?, key: String, nonce: String) -> String {
        guard let choice else { return PermissionGate.signed(.ask, key: key, nonce: nonce) }
        return "choose \(choice) " + PermissionGate.mac(key: key, message: "choose:\(nonce):\(choice)")
    }

    /// One printable line, no control or format character, cut with an ellipsis.
    static func clean(_ text: String, _ limit: Int) -> String? {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return " "
            default: return scalar
            }
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !visible.isEmpty else { return nil }
        return visible.count <= limit ? visible : String(visible.prefix(limit - 1)) + "…"
    }
}
