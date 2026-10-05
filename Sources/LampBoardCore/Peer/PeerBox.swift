import Foundation

/// Claude Code's own message box (D81): from 2.1.224 every session listens on
/// a socket named in its file under `~/.claude/sessions/`, and takes a message
/// from whoever holds the key Claude Code keeps beside that file.
///
/// Measured on the test Mac with 2.1.289 (5 October 2026): a message sent to an
/// idle session starts a turn at once; one sent to a busy session is taken into
/// the running turn. The socket answers nothing — what happened is read in the
/// transcript. Claude Code wraps the message as another session's, "not typed
/// by your user", and holds it to the session's own permissions: the box can ask
/// for work, never grant itself more than the session already has.
public enum PeerBox {

    /// The protocol this panel speaks, as the session file declares it.
    public static let protocolVersion = 1
    /// Who the messages are from, in the transcript's `origin.from`.
    public static let sender = "lampboard"
    /// Largest message carried, like the mailbox's (D15).
    public static let maxBytes = 64 * 1024

    /// The line every message from the panel starts with. Claude Code says the
    /// message came from another session; this says whose words they are, and
    /// it is how the conversation knows them again, together with `from`. Both
    /// are the sender's own word — Claude Code records which process wrote
    /// (`verifiedPeerPid`), not who it is — so a process of the user's own that
    /// reads a key could send the same; that is the account boundary the
    /// mailbox already has (D15), and the conversation only shows it.
    public static let preamble = "Typed by the user in LampBoard, the panel on this Mac where they watch their sessions:"

    public struct Address: Sendable, Equatable {
        public let pid: Int
        public let sessionId: String
        public let socketPath: String
        public let procStart: String?
        /// Mid-turn: a message is taken into the running turn, not a new one.
        public let busy: Bool
    }

    /// The box a session file names, if the session has one this panel can use.
    public static func address(fromSessionFile data: Data) -> Address? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["peerProtocol"] as? Int == protocolVersion,
              let pid = object["pid"] as? Int, pid > 0,
              let session = object["sessionId"] as? String, ModReport.isSessionId(session),
              let socket = object["messagingSocketPath"] as? String, isSocketPath(socket)
        else { return nil }
        return Address(pid: pid, sessionId: session, socketPath: socket,
                       procStart: object["procStart"] as? String, busy: object["status"] as? String == "busy")
    }

    /// `<pid>.<hex>.key`, the key Claude Code keeps for that process.
    public static func keyFileName(pid: Int, in names: [String]) -> String? {
        let prefix = "\(pid)."
        return names.first { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".key") else { return false }
            let middle = name.dropFirst(prefix.count).dropLast(".key".count)
            return !middle.isEmpty && middle.allSatisfy(\.isHexDigit)
        }
    }

    /// The key, if it was written for this very process: a pid handed on to
    /// another after the session died must not be written to.
    public static func token(fromKeyFile data: Data, procStart: String?) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["peerToken"] as? String,
              (8...256).contains(token.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let procStart, object["procStart"] as? String == procStart
        else { return nil }
        return token
    }

    /// What goes down the socket: the key, then the message. `nil` when there
    /// is nothing to send, or too much.
    public static func wire(token: String, typed: String) -> Data? {
        let text = typed.trimmed
        guard !text.isEmpty else { return nil }
        return wire(token: token, content: preamble + "\n" + text)
    }

    /// The same two lines with a content of the panel's own making, as a
    /// question without disturbing is (D82).
    public static func wire(token: String, content: String) -> Data? {
        guard !content.isEmpty, content.utf8.count <= maxBytes else { return nil }
        let auth: [String: Any] = ["type": "auth", "token": token]
        let user: [String: Any] = [
            "type": "user", "from": sender, "priority": "next",
            "message": ["role": "user", "content": content],
        ]
        guard let first = try? JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys]),
              let second = try? JSONSerialization.data(withJSONObject: user, options: [.sortedKeys])
        else { return nil }
        return first + Data("\n".utf8) + second + Data("\n".utf8)
    }

    /// What the user typed, out of a message from the panel as the transcript
    /// keeps it: inside Claude Code's envelope when it started a turn, bare when
    /// it was taken mid-turn. `nil` when it does not start with the preamble.
    public static func typed(fromDelivered text: String) -> String? {
        var body = Substring(text)
        if body.hasPrefix(envelopeHead) { body = body.dropFirst(envelopeHead.count) }
        guard body.hasPrefix(preamble) else { return nil }
        body = body.dropFirst(preamble.count)
        if let tail = body.range(of: envelopeTail) { body = body[..<tail.lowerBound] }
        return String(body).trimmed.nilIfEmpty
    }

    // MARK: - Internals

    /// Claude Code's wrapping, as 2.1.289 writes it.
    static let envelopeHead = "Another Claude session sent a message:\n"
    static let envelopeTail = "\n\nThis came from another Claude session"

    /// Absolute, a `.sock`, no `..`, and short enough for `sun_path`.
    static func isSocketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".sock") && !path.contains("/../")
            && path.utf8.count < 104 && !path.contains("\0")
    }
}
