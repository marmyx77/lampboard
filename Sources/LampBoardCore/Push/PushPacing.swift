import Foundation

/// How many Live Activity updates a source may send one device: a few at once,
/// then one every `refill` seconds.
///
/// WHY THIS EXISTS
/// A session starting or stopping to wait for the person updated the Live
/// Activity at once, with no ceiling. On 24 October 2026 a node with a dozen
/// sessions sent 121 updates in sixteen minutes. The relay allows 120 an hour
/// (`relay/lib/quota.js`): it answered "quota" and asked for 32 minutes, and the
/// lock screen stood still for them. Seen on 21 October as well.
///
/// An update the budget refuses is not lost: the source has not recorded it as
/// sent, so the next look sends it once a token has come back.
public struct LiveActivityBudget: Equatable, Sendable {
    /// Updates that can go at once after a quiet spell: the first wait after a
    /// calm one still shows at once.
    public static let burst: Double = 6
    /// One more every this many seconds: 100 an hour, so a full burst at the top
    /// of the relay's hour still leaves it under 120.
    public static let refill: TimeInterval = 36

    private var tokens: Double = LiveActivityBudget.burst
    private var at: Date?

    public init() {}

    /// Whether an update may go at `now`. One is spent when it may.
    public mutating func take(at now: Date) -> Bool {
        if let at { tokens = min(Self.burst, tokens + max(0, now.timeIntervalSince(at)) / Self.refill) }
        at = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// What the relay asked a source to hold back, kind by kind.
///
/// The relay counts its quotas per kind: alerts, background pushes and Live
/// Activity updates apart. A source that held everything back on any "quota"
/// let a spent Live Activity quota silence a permission question for half an
/// hour (24 October 2026). The wait now applies to the kind that was refused.
public struct RelayHolds: Equatable, Sendable {
    private var until: [PushKind: Date] = [:]

    public init() {}

    /// The relay's answer to a push of `kind`, sent at `now`.
    public mutating func heard(_ outcome: RelayOutcome, for kind: PushKind, at now: Date) {
        switch outcome {
        case .quota(let seconds): until[kind] = now.addingTimeInterval(TimeInterval(seconds))
        case .ok: until[kind] = nil
        default: break
        }
    }

    /// Whether pushes of `kind` wait at `now`.
    public func holds(_ kind: PushKind, at now: Date) -> Bool {
        until[kind].map { $0 > now } ?? false
    }

    /// Whether anything waits at `now`: the health check is not asked meanwhile.
    public func any(at now: Date) -> Bool {
        until.values.contains { $0 > now }
    }
}
