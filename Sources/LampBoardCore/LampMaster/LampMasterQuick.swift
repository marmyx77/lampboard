import Foundation

/// The quick round (D72): a look now, rather than at the hour, when a session
/// starts repeating a failure or stops moving.
///
/// Those two are where a session burns time and where another session's
/// knowledge can help: somebody may have fixed that failure yesterday, or be
/// the reason for the wait. The other signals need no hurry — a full context
/// already shows on the row's ring, and its remedy, `/compact`, needs no model
/// to suggest it; overlaps and finished work keep until the hour.
///
/// Sonnet, whatever the hourly round uses. The plan said a small model; on the
/// test Mac, on the same frame, Haiku spent 36 to 56 seconds and 5,600 tokens
/// thinking before its first word, for 0.020 to 0.037 dollars, and Sonnet
/// answered in 6.5 seconds for 0.016 (4 October 2026). A quick round that comes
/// a minute late is not quick.
public enum LampMasterQuick {

    /// The least time after any round: a turn that fails three times in a
    /// minute is one event, not three.
    public static let spacing: TimeInterval = 10 * 60
    /// A bad day of failing builds must not spend the allowance: past six,
    /// the hourly round still sees everything.
    public static let perDay = 6
    public static let model = "sonnet"

    /// The urgent signals of a frame's sessions, one stable key per session and
    /// signal: the same failure in the same session is the same key all hour.
    public static func urgent(_ signals: [String: [LampMasterSignal]]) -> Set<String> {
        var keys = Set<String>()
        for (id, list) in signals {
            for signal in list {
                switch signal {
                case .repeatedFailure(let fingerprint): keys.insert("\(id) failure \(fingerprint)")
                case .stuck: keys.insert("\(id) stuck")
                default: break
                }
            }
        }
        return keys
    }

    public static func urgent(in frame: LampMasterFrame) -> Set<String> {
        urgent(Dictionary(frame.sessions.map { ($0.id, $0.signals) }, uniquingKeysWith: +))
    }

    /// Whether a quick round has something to look at. Not due is not a skip:
    /// nothing is recorded, or every turn's end would write a line.
    ///
    /// - Parameter seen: the pairs the last round that reached `claude` saw,
    ///   whatever started it — the hourly round answers them too.
    public static func due(urgent: Set<String>, seen: Set<String>, lastRun: Date?, quickToday: Int, now: Date) -> Bool {
        guard !urgent.subtracting(seen).isEmpty, quickToday < perDay else { return false }
        return lastRun.map { now.timeIntervalSince($0) >= spacing } ?? true
    }

    /// The quick rounds that reached `claude` on the day `now` falls on.
    public static func count(on now: Date, in rounds: [LampMasterRound], calendar: Calendar = .current) -> Int {
        rounds.filter { $0.trigger == .quick && $0.outcome != .skipped && calendar.isDate($0.at, inSameDayAs: now) }.count
    }
}
