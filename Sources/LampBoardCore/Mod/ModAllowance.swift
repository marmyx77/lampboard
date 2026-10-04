import Foundation

/// This Mac's allowance with the mod's figures in it (D67).
///
/// A session counts its account's windows on every response, and the mod passes
/// them on: fresher than any ask of Anthropic's usage service, and free, with no
/// credential borrowed and nothing leaving the Mac. So when the mod has spoken
/// for the default account, its session and week bars are the ones drawn, and
/// the service becomes the reserve — still the only source for a model's own
/// weekly cap, which the session does not report, and for the account's name.
public enum ModAllowance {

    /// - Parameters:
    ///   - reports: what the usage service gave, local first, as the strip had it.
    ///   - mod: the newest windows the default account's sessions reported.
    ///   - machine: the label of this Mac's report.
    public static func merged(
        _ reports: [AllowanceReport], mod: (limits: [ModReport.RateLimit], at: Date)?, machine: String
    ) -> [AllowanceReport] {
        guard let mod else { return reports }
        let bars = mod.limits.compactMap(bar)
        guard !bars.isEmpty else { return reports }
        guard let local = reports.first, local.machine == machine else {
            // Nothing from the service for this Mac: the mod's bars alone, labelled
            // by the machine, since a session does not say whose account it is.
            return [AllowanceReport(account: nil, machine: machine, limits: AccountLimits(limits: bars, readAt: mod.at))]
                + reports
        }
        // The service's answer is newer: nothing to improve on.
        guard mod.at > local.limits.readAt else { return reports }
        let spans = Set(bars.map { "\($0.span)" })
        let kept = local.limits.limits.filter { !spans.contains("\($0.span)") }
        let limits = AccountLimits(limits: bars + kept, readAt: mod.at)
        return [AllowanceReport(account: local.account, machine: local.machine, limits: limits)] + reports.dropFirst()
    }

    /// `five_hour` and `seven_day` are the bars the strip draws as session and
    /// week; anything else (a gateway's spend limit) has no bar here.
    static func bar(_ limit: ModReport.RateLimit) -> AccountLimits.Limit? {
        switch limit.kind {
        case "five_hour": return AccountLimits.Limit(span: .session, percent: limit.percent, resetsAt: limit.resetsAt)
        case "seven_day": return AccountLimits.Limit(span: .week, percent: limit.percent, resetsAt: limit.resetsAt)
        default: return nil
        }
    }
}
