import Foundation

/// One account's allowance, and where it was read.
///
/// The panel draws one group of bars per report. There is more than one because a
/// person can be signed into different accounts on different machines — measured
/// here: an organization account on this Mac, a personal one on the node the tunnel
/// reaches, on two different plans with two different-sized allowances.
public struct AllowanceReport: Equatable, Sendable {

    /// Whose allowance this is. `nil` when the machine could not say, which is
    /// survivable: the machine's own name is then the label.
    public let account: ClaudeAccount?

    /// Where it was read: this Mac, or the host it came from.
    public let machine: String

    public let limits: AccountLimits

    public init(account: ClaudeAccount?, machine: String, limits: AccountLimits) {
        self.account = account
        self.machine = machine
        self.limits = limits
    }

    /// What to write above the bars.
    public var label: String {
        account?.label(fallback: machine) ?? machine
    }

    /// Collapses readings of the same account, keeping the first of each.
    ///
    /// Two machines signed into one account is the ordinary case for anybody with a
    /// laptop and a build box, and drawing its bars twice would tell the person
    /// they have twice the room. The first is kept rather than the fullest: the
    /// caller puts the local reading first, and that is the one whose age this app
    /// controls — a remote reading is as fresh as the last time the tunnel answered.
    ///
    /// Reports with no uuid are never merged into anything. An account that cannot
    /// prove which one it is gets its own group: showing one group twice is a
    /// smaller failure than silently hiding a second account's allowance, which is
    /// precisely the failure this whole type exists to undo.
    public static func merged(_ reports: [AllowanceReport]) -> [AllowanceReport] {
        var kept: [AllowanceReport] = []
        for report in reports {
            let duplicate = kept.contains { existing in
                guard let mine = report.account, let theirs = existing.account else { return false }
                return mine.isSameAccount(as: theirs)
            }
            if !duplicate { kept.append(report) }
        }
        return kept
    }
}
