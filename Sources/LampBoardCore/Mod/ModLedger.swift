import Foundation

/// What the mod has said about each session, kept beside the column's state.
///
/// Not in `SessionState`: a row is built from the hooks and the transcripts,
/// and it must read the same whether a session has the mod or not (D65). This
/// is the extra the mod brings — cost, surface, rate limits, why it ended —
/// for the places that show it, and the proof that a session has the mod.
public struct ModLedger: Equatable, Sendable {

    public struct Facts: Equatable, Sendable {
        public let surface: String?
        public let interactive: Bool?
        public let model: String?
        public let costUSD: Double?
        public let rateLimits: [ModReport.RateLimit]
        /// When the rate limits were read: the account's figures are the newest
        /// any session reported, not the last session that spoke.
        public let rateLimitsAt: Date?
        public let ended: ModReport.EndReason?
        public let heardAt: Date
        /// Whether its windows are this Mac's default account's (`Measure`).
        public let defaultAccount: Bool
        /// The tools running now, by call id, with when each began.
        public var running: [String: RunningTool] = [:]
        /// Calls already finished. The mod does not wait for its posts, so a
        /// fast tool's "end" can arrive before its "start", and the late start
        /// must not put a call that is over back on the list.
        public var finished: [String] = []

        public init(
            surface: String? = nil, interactive: Bool? = nil, model: String? = nil, costUSD: Double? = nil,
            rateLimits: [ModReport.RateLimit] = [], rateLimitsAt: Date? = nil,
            ended: ModReport.EndReason? = nil, heardAt: Date, defaultAccount: Bool = false
        ) {
            self.defaultAccount = defaultAccount
            self.surface = surface
            self.interactive = interactive
            self.model = model
            self.costUSD = costUSD
            self.rateLimits = rateLimits
            self.rateLimitsAt = rateLimitsAt
            self.ended = ended
            self.heardAt = heardAt
        }
    }

    public let sessions: [String: Facts]

    /// More tools at once than a session runs; a sender that never says "end"
    /// cannot grow the list.
    public static let maxRunning = 32

    public init(sessions: [String: Facts] = [:]) {
        self.sessions = sessions
    }

    /// A bound on what a misbehaving sender can make the panel hold: the
    /// sessions heard least recently go first. Far above any real day (the
    /// heaviest measured is about 24 sessions at once).
    public static let maxSessions = 300

    public func applying(_ report: ModReport, now: Date) -> ModLedger {
        // An answer is a reply to the panel's question, not a fact about the session.
        if case .answer = report { return self }
        if case .done = report { return self }
        if case .stopped = report { return self }
        if case .presence = report { return self }
        let old = sessions[report.session]
        var facts: Facts
        switch report {
        case .start(_, let start):
            facts = Facts(
                surface: start.surface, interactive: start.interactive, model: start.model ?? old?.model,
                costUSD: old?.costUSD, rateLimits: old?.rateLimits ?? [], rateLimitsAt: old?.rateLimitsAt,
                ended: nil, heardAt: now, defaultAccount: old?.defaultAccount ?? false
            )
        case .measure(_, let measure):
            // An empty list is "no reading yet" or "not a subscription", never
            // "every window went back to zero": the last figures stay.
            let fresh = !measure.rateLimits.isEmpty
            facts = Facts(
                surface: old?.surface, interactive: old?.interactive, model: measure.model ?? old?.model,
                costUSD: measure.costUSD ?? old?.costUSD,
                rateLimits: fresh ? measure.rateLimits : old?.rateLimits ?? [],
                rateLimitsAt: fresh ? now : old?.rateLimitsAt,
                ended: old?.ended, heardAt: now, defaultAccount: measure.defaultAccount
            )
        case .tool(_, let run):
            var next = old ?? Facts(heardAt: now)
            if run.finished {
                next.running[run.id] = nil
                next.finished = Array((next.finished + [run.id]).suffix(Self.maxRunning * 2))
            } else if !next.finished.contains(run.id), next.running.count < Self.maxRunning,
                      !Self.untracked.contains(run.tool) {
                next.running[run.id] = RunningTool(tool: run.tool, detail: run.detail, since: now)
            }
            facts = next.heard(at: now)
        case .answer, .done, .stopped, .presence:
            return self
        case .end(_, let reason):
            facts = Facts(
                surface: old?.surface, interactive: old?.interactive, model: old?.model, costUSD: old?.costUSD,
                rateLimits: old?.rateLimits ?? [], rateLimitsAt: old?.rateLimitsAt, ended: reason, heardAt: now,
                defaultAccount: old?.defaultAccount ?? false
            )
        }
        // A measure says nothing about the tools: what was running still is.
        if case .measure = report { facts.running = old?.running ?? [:] }
        // An end clears them by construction: whatever was running ends with
        // the session, said or not.
        var next = sessions
        next[report.session] = facts
        if next.count > Self.maxSessions {
            let oldest = next.sorted { $0.value.heardAt < $1.value.heardAt }.prefix(next.count - Self.maxSessions)
            oldest.forEach { next[$0.key] = nil }
        }
        return ModLedger(sessions: next)
    }

    /// A subagent's call runs as long as the whole subagent, and would read as
    /// stuck while hiding the inner tool that really is.
    public static let untracked: Set<String> = ["Agent", "Task"]

    /// The tool running longest in a session, among those started since the
    /// row began working: one from an earlier turn whose "end" never came is
    /// not this turn's.
    public func longestRunning(in session: String, since start: Date = .distantPast) -> RunningTool? {
        sessions[session]?.running.values.filter { $0.since >= start.addingTimeInterval(-5) }.min { $0.since < $1.since }
    }

    /// Only the sessions the column still has: the rest is history nobody draws.
    public func keeping(_ ids: Set<String>) -> ModLedger {
        ModLedger(sessions: sessions.filter { ids.contains($0.key) })
    }

    /// The newest rate-limit figures any session on this Mac's default account
    /// reported, with when. Only those: the strip they join is that account's.
    public var latestRateLimits: (limits: [ModReport.RateLimit], at: Date)? {
        sessions.values
            .filter(\.defaultAccount)
            .compactMap { facts in facts.rateLimitsAt.map { (facts.rateLimits, $0) } }
            .max { $0.1 < $1.1 }
            .map { (limits: $0.0, at: $0.1) }
    }
}

/// A tool a session is running, and since when (5.7).
public struct RunningTool: Equatable, Sendable {
    public let tool: String
    public let detail: String?
    public let since: Date

    public init(tool: String, detail: String?, since: Date) {
        self.tool = tool
        self.detail = detail
        self.since = since
    }

    /// Longer than this on one tool and a working row says it may be stuck:
    /// a build or a test suite can honestly take ten minutes, a command left
    /// waiting on input never ends.
    public static let stuckAfter: TimeInterval = 15 * 60

    public func isStuck(at now: Date) -> Bool { now.timeIntervalSince(since) >= Self.stuckAfter }

    /// `Bash: npm test`, as a row's card says it.
    public var sentence: String { detail.map { "\(tool): \($0)" } ?? tool }
}

extension ModLedger.Facts {
    /// The same facts, heard again now.
    func heard(at now: Date) -> ModLedger.Facts {
        var copy = ModLedger.Facts(
            surface: surface, interactive: interactive, model: model, costUSD: costUSD, rateLimits: rateLimits,
            rateLimitsAt: rateLimitsAt, ended: ended, heardAt: now, defaultAccount: defaultAccount
        )
        copy.running = running
        copy.finished = finished
        return copy
    }
}
