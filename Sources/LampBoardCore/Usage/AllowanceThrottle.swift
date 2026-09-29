import Foundation

/// What the strip does when Anthropic answers 429: slow down, and keep what it
/// already knew.
///
/// WHY
/// The usage endpoint is shared by everything that asks it for one account:
/// Claude Code itself, the Claude application, and this panel — once per machine
/// the account is signed in on, and once more for each session the application
/// runs there. Measured on 29 September 2026: with one account signed in on the
/// node's command line **and** running the application's sessions there, the
/// panel asked for it twice a poll, and the answer became 429. The strip then
/// went empty and said "answered 429", which threw away a reading two minutes old
/// to show nothing at all.
///
/// So a refusal to answer is not treated as a lack of figures. The last reading
/// of each account stays on screen with its age — every card says how old it is
/// — until it is too old to be worth showing, and the next ask waits longer each
/// time the answer is still 429.
public enum AllowanceThrottle {

    /// How long a reading may be shown in place of one that was refused.
    ///
    /// Half an hour: the five-hour window moves a few points in that time, which
    /// the card's age makes visible; past it the figure is history, not a gauge.
    public static let keepFor: TimeInterval = 30 * 60

    /// The longest wait between two asks, however many refusals in a row.
    public static let ceiling: TimeInterval = 20 * 60

    /// The wait before the next ask, after `streak` refusals in a row.
    ///
    /// Doubles from the ordinary interval and stops at the ceiling. No refusal,
    /// no change: the ordinary interval is the one the rest of the app chose.
    public static func interval(afterRefusals streak: Int, base: TimeInterval) -> TimeInterval {
        guard streak > 0 else { return base }
        let doubled = base * pow(2, Double(min(streak, 16)))
        return min(doubled, max(ceiling, base))
    }

    /// The reports to draw after a gathering that was refused somewhere.
    ///
    /// Every fresh report is kept. Then every earlier one whose account is not
    /// among them and that is still young enough comes back, as it was, with its
    /// own reading time — never restamped, or the card would lie about its age.
    /// A report that names no account cannot be matched to a fresh one and is
    /// carried only when nothing fresh arrived from its machine.
    public static func carriedOver(
        previous: [AllowanceReport],
        fresh: [AllowanceReport],
        now: Date,
        keepFor: TimeInterval = keepFor
    ) -> [AllowanceReport] {
        var kept = fresh
        for old in previous where now.timeIntervalSince(old.limits.readAt) <= keepFor {
            let replaced = fresh.contains { new in
                if let mine = old.account, let theirs = new.account {
                    return mine.isSameAccount(as: theirs)
                        || (mine.uuid == nil && theirs.uuid == nil && mine.email == theirs.email)
                }
                return old.account == nil && new.account == nil && old.machine == new.machine
            }
            if !replaced { kept.append(old) }
        }
        return AllowanceReport.merged(kept)
    }
}
