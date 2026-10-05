import Foundation

/// The allowance in the round's frame, and the round giving way to it (D4).
///
/// The forecast is the pace so far: a window five hours long, two hours in at
/// 60 %, ends at 150 %. It needs no history the panel does not keep, and it
/// says nothing early in a window, when a burst would read as a pace.
public enum LampMasterQuota {

    /// Below this share of a window gone, there is no pace to speak of.
    static let earliest = 0.15

    static func length(_ span: AccountLimits.Limit.Span) -> TimeInterval {
        switch span {
        case .session: return 5 * 3_600
        case .week, .weekForModel: return 7 * 24 * 3_600
        }
    }

    /// The share of the window it ends at, at this pace; `nil` when it cannot be told.
    static func projected(_ limit: AccountLimits.Limit, now: Date) -> Double? {
        let used = Double(limit.percent) / 100
        if used >= 1 { return used }
        guard let resetsAt = limit.resetsAt else { return nil }
        let span = length(limit.span)
        let elapsed = span - resetsAt.timeIntervalSince(now)
        guard elapsed >= span * earliest, elapsed <= span else { return nil }
        return used * span / elapsed
    }

    /// Whether this window runs out before it resets, at the pace so far.
    public static func runsOut(_ limit: AccountLimits.Limit, now: Date) -> Bool {
        (projected(limit, now: now) ?? 0) >= 1
    }

    /// One line per account, as the allowance strip reads them, with the
    /// window most at risk: the round does not redo the arithmetic.
    public static func frame(_ reports: [AllowanceReport], now: Date) -> [LampMasterFrame.Quota] {
        reports.compactMap { report in
            let risk = { (limit: AccountLimits.Limit) in projected(limit, now: now) ?? Double(limit.percent) / 100 }
            guard let worst = report.limits.limits.max(by: { risk($0) < risk($1) }) else { return nil }
            return LampMasterFrame.Quota(
                account: report.label, used: Double(worst.percent) / 100,
                resetInMinutes: worst.resetsAt.map { max(0, Int($0.timeIntervalSince(now) / 60)) },
                runsOutBeforeReset: runsOut(worst, now: now)
            )
        }
    }

    /// The round spends the account `claude` uses on this Mac — the strip's
    /// first report — and only its session and weekly windows: a model's own
    /// cap is not the round's.
    public static func tight(_ reports: [AllowanceReport], now: Date) -> Bool {
        guard let mine = reports.first else { return false }
        return mine.limits.limits.contains { limit in
            if case .weekForModel = limit.span { return false }
            return runsOut(limit, now: now)
        }
    }
}
