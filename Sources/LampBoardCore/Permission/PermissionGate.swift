import CryptoKit
import Foundation

/// Allow and Deny from the panel (D73): a permission a session's companion mod
/// puts to the panel instead of the session's own dialog, and the rules that
/// keep that safe.
///
/// Measured on the test Mac (AD0): a mod's `tool.check` may wait on the panel
/// for about a minute, past which Claude Code drops the hook and its own verdict
/// stands; and a mod answering `ask` brings the session's ordinary dialog back.
/// So the panel has 55 seconds, and anything it does not answer goes back to the
/// dialog it would have had.
public enum PermissionGate {

    /// The panel's time to answer: under the minute Claude Code gives a hook,
    /// with room for the answer to travel back.
    public static let answerWithin: TimeInterval = 55
    /// Asks waiting at once: past eight, an ask goes to its dialog at once,
    /// which is where it would have gone without the panel.
    public static let pendingMax = 8

    public enum Verdict: String, Sendable, Equatable {
        case allow, deny, ask
    }

    /// One ask: which session, which call, which tool, and the one line worth
    /// showing — the first line of a command or a path, masked like the mod's
    /// tool lines are.
    public struct Request: Sendable, Equatable, Identifiable {
        public var id: String { callId }
        public let sessionId: String
        public let callId: String
        public let tool: String
        public let line: String
        public let receivedAt: Date
        /// A question's options (D86); empty for a permission.
        public let options: [String]

        /// Past its time with the panel: a question's is shorter (D86).
        func isDue(at now: Date) -> Bool {
            now.timeIntervalSince(receivedAt) >= (options.isEmpty ? PermissionGate.answerWithin : QuestionGate.answerWithin)
        }

        public init(sessionId: String, callId: String, tool: String, line: String, receivedAt: Date, options: [String] = []) {
            self.sessionId = sessionId
            self.callId = callId
            self.tool = tool
            self.line = line
            self.receivedAt = receivedAt
            self.options = options
        }
    }

    /// The body the mod posts: `{"v":1,"session","id","tool","detail"?}`.
    /// Anything malformed is refused rather than guessed at: a refused ask
    /// falls back to the session's dialog.
    public static func decode(_ data: Data, at now: Date) -> Request? {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == ModReport.version,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let call = object["id"] as? String, ModReport.isCallId(call),
              let rawTool = object["tool"] as? String, let tool = ModReport.toolName(rawTool)
        else { return nil }
        let detail = (object["detail"] as? String).flatMap(ModReport.detail)
        let line = detail.map { "\(tool): \($0)" } ?? tool
        return Request(sessionId: session, callId: call, tool: tool, line: line, receivedAt: now)
    }

    // MARK: - Proof
    //
    // A project's settings can point the mod's LAMPBOARD_HOME at a folder of its
    // own, with a key and a port of its choosing, and a listener there could
    // answer "allow" (a security review finding). So the mod finds the panel's
    // permission key from HOME, sends it nowhere, and proves it holds it; and
    // the panel proves the same in its answer. The key is not the token, which
    // every hook and report carries to whatever answers on the port (a second
    // review finding). A listener without the key can neither be asked nor answer.

    /// HMAC-SHA256 in lowercase hex: what the mod computes by hand from
    /// `crypto.subtle.digest`, the one primitive its runtime offers.
    public static func mac(key: String, message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    public static func askMessage(nonce: String, session: String, call: String) -> String {
        "ask:\(nonce):\(session):\(call)"
    }

    /// Whether an ask's proof was made with this key for this call.
    public static func isGenuine(key: String, nonce: String, proof: String, session: String, call: String) -> Bool {
        return proves(proof, mac(key: key, message: askMessage(nonce: nonce, session: session, call: call)), nonce: nonce)
    }

    /// The comparison, in constant time, once the nonce and the proof have the
    /// shape they must.
    static func proves(_ proof: String, _ expected: String, nonce: String) -> Bool {
        guard (16...64).contains(nonce.count), proof.count == 64 else { return false }
        return expected.utf8.count == proof.utf8.count && zip(expected.utf8, proof.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The answer as the mod checks it: the verdict and its signature.
    public static func signed(_ verdict: Verdict, key: String, nonce: String) -> String {
        verdict.rawValue + " " + mac(key: key, message: "answer:\(nonce):\(verdict.rawValue)")
    }

    /// The asks waiting for the panel.
    public struct Book: Sendable, Equatable {
        public private(set) var pending: [Request] = []

        public init() {}

        /// `false` when the call is already waiting or the book is full: the
        /// ask then goes to its dialog.
        public mutating func add(_ request: Request) -> Bool {
            guard pending.count < PermissionGate.pendingMax, !pending.contains(where: { $0.callId == request.callId && $0.sessionId == request.sessionId })
            else { return false }
            pending.append(request)
            return true
        }

        /// The verdict, once: a second answer, or one for a call nobody asked
        /// about, changes nothing.
        public mutating func answer(session: String, call callId: String, _ verdict: Verdict) -> Verdict? {
            guard let index = pending.firstIndex(where: { $0.callId == callId && $0.sessionId == session }) else { return nil }
            pending.remove(at: index)
            return verdict
        }

        /// The asks whose time is up, taken out of the book: each goes back to
        /// its session's dialog.
        public mutating func expired(at now: Date) -> [Request] {
            let gone = pending.filter { $0.isDue(at: now) }
            pending.removeAll { $0.isDue(at: now) }
            return gone
        }
    }
}
