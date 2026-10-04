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

    /// The asks waiting for the panel.
    public struct Book: Sendable, Equatable {
        public private(set) var pending: [Request] = []

        public init() {}

        /// `false` when the call is already waiting or the book is full: the
        /// ask then goes to its dialog.
        public mutating func add(_ request: Request) -> Bool {
            guard pending.count < PermissionGate.pendingMax, !pending.contains(where: { $0.callId == request.callId })
            else { return false }
            pending.append(request)
            return true
        }

        /// The verdict, once: a second answer, or one for a call nobody asked
        /// about, changes nothing.
        public mutating func answer(_ callId: String, _ verdict: Verdict) -> Verdict? {
            guard let index = pending.firstIndex(where: { $0.callId == callId }) else { return nil }
            pending.remove(at: index)
            return verdict
        }

        /// The asks whose time is up, taken out of the book: each goes back to
        /// its session's dialog.
        public mutating func expired(at now: Date) -> [Request] {
            let gone = pending.filter { now.timeIntervalSince($0.receivedAt) >= PermissionGate.answerWithin }
            pending.removeAll { now.timeIntervalSince($0.receivedAt) >= PermissionGate.answerWithin }
            return gone
        }
    }
}
