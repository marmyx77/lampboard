import Foundation

/// What each account's line at the foot of the column says (U1).
///
/// Two faults reported on 7 October 2026, both on a panel signed into two
/// accounts: the two lines were both called «marco», because the name kept only
/// the part before the @, and the second said «0% —», a window that had not
/// started, which reads as a broken figure rather than as nothing to count yet.
public enum AllowanceLines {

    /// Above this a limit counts as spent, and takes the line from the session
    /// window. Not 100: a week at 94% will stop the work before it resets, and a
    /// line that waited for the round number would tell somebody at the moment it
    /// stopped being useful.
    public static let spent = 90

    /// The limit an account's line shows, or nil for no line.
    ///
    /// The five-hour window, which is the one that stops the work today and comes
    /// back this afternoon — unless another limit is spent, and then that one is
    /// binding. A window that has not started (nothing used, no reset time) has no
    /// line at all.
    public static func shown(in report: AllowanceReport) -> AccountLimits.Limit? {
        let limits = report.limits.limits
        if let binding = limits.filter({ $0.span != .session && $0.percent >= spent }).max(by: { $0.percent < $1.percent }) {
            return binding
        }
        if let session = limits.first(where: { $0.span == .session }) {
            return hasStarted(session) ? session : nil
        }
        return limits.max { $0.percent < $1.percent }
    }

    /// Whether a limit is counting: something used, or a reset on the clock.
    public static func hasStarted(_ limit: AccountLimits.Limit) -> Bool {
        limit.percent > 0 || limit.resetsAt != nil
    }

    /// One short name per label, in the same order.
    ///
    /// The part before the @, which is what a person calls an account — unless two
    /// accounts share it, and then the domain, which is the half that differs. A
    /// machine name carries no @ and is kept whole; two identical labels stay
    /// whole, since nothing shorter tells them apart.
    public static func names(for labels: [String]) -> [String] {
        let locals = labels.map(localPart)
        return labels.enumerated().map { index, label in
            let local = locals[index]
            guard label.contains("@") else { return label }
            if locals.filter({ $0 == local }).count == 1 { return local }
            let domain = domainPart(label)
            let sameDomain = labels.enumerated().contains { $0.offset != index && localPart($0.element) == local && domainPart($0.element) == domain }
            return sameDomain ? label : domain
        }
    }

    private static func localPart(_ label: String) -> String {
        label.split(separator: "@", maxSplits: 1).first.map(String.init) ?? label
    }

    private static func domainPart(_ label: String) -> String {
        label.split(separator: "@", maxSplits: 1).last.map(String.init) ?? label
    }
}
