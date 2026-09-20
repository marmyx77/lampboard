import Foundation

/// How much of the account's allowance is gone, and when it comes back.
///
/// This is the one figure in the panel that is **not about a row**. Every other
/// number here belongs to a session: the state, the context ring, the model. The
/// allowance belongs to the account, so it is drawn once, at the foot of the
/// column. Putting it on each row would mean saying the same thing six times, and
/// six copies of one fact read as six facts.
///
/// WHERE THE FIGURES COME FROM, AND WHY NOT FROM THE CHEAPER PLACE
/// Claude Code keeps its own copy in `~/.claude.json` under
/// `cachedUsageUtilization`, free to read and needing no credentials. It is not
/// used, and the reason is a measurement: on 20 September 2026 that cache said the
/// five-hour window was at 0% and the week at 6%, while the account was really at
/// 9% and 15%. It had been written fifteen hours earlier. Claude Code rewrites it
/// at most every five minutes and treats it as dead after an hour, so it is
/// correct *for Claude Code*, which refetches when it finds it stale; a reader that
/// only ever looks would show a number that is plausible, precise and wrong. A
/// number nobody can tell is stale is worse than no number.
///
/// WHY `limits` AND NOT THE NAMED FIELDS
/// The answer also carries `five_hour`, `seven_day`, `seven_day_opus` and about ten
/// keys named `amber_gauge`, `cedar_ember`, `juniper_tide`, `nimbus_quill` — buckets
/// that are not announced anywhere and will be renamed without anybody being told.
/// `limits` is the same information already normalized, and it is what `/usage`
/// itself draws. Reading the shape instead of the vocabulary is the difference
/// between a panel that survives a Tuesday and one that goes blank on it.
public struct AccountLimits: Equatable, Sendable {

    /// One bar. Three of them at the time of writing; the list is read, not fixed,
    /// because a plan change adds and removes them.
    public struct Limit: Equatable, Sendable {

        /// What the limit is counted over.
        public enum Span: Equatable, Sendable {
            /// The rolling five-hour window. Claude Code calls it the session limit.
            case session
            /// Everything, over a week.
            case week
            /// One model's own weekly cap. On the account this was written against
            /// the name that arrives is `Fable` — the Fable 5.1 allowance — but the
            /// name is read from the answer and never written here: a plan change,
            /// or a different model being scoped, has to move the label with it.
            case weekForModel(String)
        }

        public let span: Span
        /// 0…100. Clamped on the way in: a bar cannot be drawn outside itself, and
        /// a figure above a hundred is a change of meaning, not a fuller bar.
        public let percent: Int
        /// When the count goes back to zero, when the answer says.
        public let resetsAt: Date?

        public init(span: Span, percent: Int, resetsAt: Date?) {
            self.span = span
            self.percent = min(max(percent, 0), 100)
            self.resetsAt = resetsAt
        }

        /// What to write beside the bar.
        public var label: String {
            switch span {
            case .session: return "session"
            case .week: return "week"
            case .weekForModel(let model): return model
            }
        }
    }

    public let limits: [Limit]
    /// When this answer was received. Drawn, not just kept: a figure with no age on
    /// it invites the reader to assume it is current, which is the mistake the
    /// on-disk cache would have made for us.
    public let readAt: Date

    public init(limits: [Limit], readAt: Date) {
        self.limits = limits
        self.readAt = readAt
    }

    /// Reads the answer from `/api/oauth/usage`.
    ///
    /// Returns `nil` only when the payload is not an object at all. An answer whose
    /// `limits` is missing or empty is **not** a failure: it is an account with
    /// nothing to report, and inventing a zero would draw three empty bars where
    /// the honest drawing is none.
    public static func decode(_ payload: Data, readAt: Date = Date()) -> AccountLimits? {
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }
        // The app's own cache nests the answer under `utilization`; the endpoint
        // returns it flat. Both shapes are read so that the two can never disagree
        // about which one this code understands.
        let object = (root["utilization"] as? [String: Any]) ?? root
        let rows = (object["limits"] as? [[String: Any]]) ?? []

        return AccountLimits(limits: rows.compactMap(limit(from:)), readAt: readAt)
    }

    // MARK: - Internal

    private static func limit(from row: [String: Any]) -> Limit? {
        guard let kind = row["kind"] as? String else { return nil }
        guard let percent = number(row["percent"]) else { return nil }
        guard let span = span(kind: kind, scope: row["scope"] as? [String: Any]) else { return nil }
        return Limit(span: span, percent: percent, resetsAt: date(row["resets_at"]))
    }

    private static func span(kind: String, scope: [String: Any]?) -> Limit.Span? {
        switch kind {
        case "session":
            return .session
        case "weekly_all":
            return .week
        case "weekly_scoped":
            // A scoped limit with nothing naming what it is scoped to cannot be
            // labelled, and a bar with no label is a bar nobody can act on. Dropped
            // rather than called "weekly" a second time next to the real one.
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            guard let model, !model.isEmpty else { return nil }
            return .weekForModel(model)
        default:
            // An unknown kind is a bucket this build has no drawing for. Ignored on
            // purpose: the answer gains and loses them without notice.
            return nil
        }
    }

    private static func number(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double.rounded()) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        // The same field arrives with and without fractional seconds depending on
        // which limit it belongs to. Both were seen in one answer.
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
