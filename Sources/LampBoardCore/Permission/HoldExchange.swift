import Foundation

/// Away, a risky command is held (§5.8, A2). Before a shell command the engine
/// would run on its own, the companion mod asks; while the person is away, one
/// that `PermissionImpact` names as destructive becomes a question, which waits
/// for their return instead of running unseen. Proven both ways with the
/// permission key, like the radar (D113).
public enum HoldExchange {

    /// The longest command read whole, in Unicode scalars; the mod sends a
    /// longer one cut there, and says so — away, it is held unread.
    public static let longest = 4000

    public struct Request: Sendable, Equatable {
        public let session: String
        public let command: String
        public let cut: Bool

        public init(session: String, command: String, cut: Bool) {
            self.session = session
            self.command = command
            self.cut = cut
        }
    }

    /// The proof covers the command and whether it was cut.
    public static func proofMessage(nonce: String, session: String, cut: Bool, command: String) -> String {
        "hold:\(nonce):\(session):\(cut ? 1 : 0):\(command)"
    }

    public static func provenRequest(_ body: Data, nonce: String?, proof: String?, key: String) -> Request? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["v"] as? Int == 1,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let command = object["command"] as? String, command.unicodeScalars.count <= longest,
              let cut = object["cut"] as? Bool,
              let nonce, let proof,
              PermissionGate.proves(proof, PermissionGate.mac(key: key, message: proofMessage(nonce: nonce, session: session, cut: cut, command: command)),
                                    nonce: nonce)
        else { return nil }
        return Request(session: session, command: command, cut: cut)
    }

    /// Why it is held, or `nil` when it goes: only away; every line read as it
    /// is, unmasked — nothing here is shown, and a mask can swallow a command;
    /// a command cut at `longest` is held unread. The rules are a fixed set of
    /// spellings (D87): a destructive command they do not name goes.
    public static func reason(command: String, cut: Bool, away: Bool) -> String? {
        guard away else { return nil }
        if cut { return "Held while you are away: this command is too long to read whole. It waits for you." }
        for line in command.split(whereSeparator: \.isNewline) {
            if let impact = PermissionImpact.of(tool: "Bash", line: String(line)), PermissionImpact.warns(impact) {
                return "Held while you are away: this command \(impact). It waits for you."
            }
        }
        return nil
    }

    /// `go <sig>`, or `hold <sig>` and the sentence on the next line.
    public static func answer(reason: String?, nonce: String, key: String) -> String {
        let verdict = reason == nil ? "go" : "hold"
        let signature = PermissionGate.mac(key: key, message: "hold:\(nonce):\(verdict):\(reason ?? "")")
        return reason.map { "\(verdict) \(signature)\n\($0)" } ?? "\(verdict) \(signature)"
    }
}
