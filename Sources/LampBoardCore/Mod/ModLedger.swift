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

    public init(sessions: [String: Facts] = [:]) {
        self.sessions = sessions
    }

    /// A bound on what a misbehaving sender can make the panel hold: the
    /// sessions heard least recently go first. Far above any real day (the
    /// heaviest measured is about 24 sessions at once).
    public static let maxSessions = 300

    public func applying(_ report: ModReport, now: Date) -> ModLedger {
        let old = sessions[report.session]
        let facts: Facts
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
        case .end(_, let reason):
            facts = Facts(
                surface: old?.surface, interactive: old?.interactive, model: old?.model, costUSD: old?.costUSD,
                rateLimits: old?.rateLimits ?? [], rateLimitsAt: old?.rateLimitsAt, ended: reason, heardAt: now,
                defaultAccount: old?.defaultAccount ?? false
            )
        }
        var next = sessions
        next[report.session] = facts
        if next.count > Self.maxSessions {
            let oldest = next.sorted { $0.value.heardAt < $1.value.heardAt }.prefix(next.count - Self.maxSessions)
            oldest.forEach { next[$0.key] = nil }
        }
        return ModLedger(sessions: next)
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
