import Foundation

/// When the round runs, and when it does not, at no cost.
///
/// Every skip is decided here, before a token is spent: switched off, nobody
/// to look at, nothing new since the last round, or the day's ceiling reached.
/// "Nothing new" is what keeps the cost down on a quiet evening: twelve
/// identical frames an hour apart would buy twelve identical answers.
public enum LampMasterSchedule {

    public static let defaultInterval: TimeInterval = 60 * 60
    /// Thirty minutes is the most a person reads suggestions; two hours the
    /// least before a waiting session is old news.
    public static let intervalRange: ClosedRange<TimeInterval> = (30 * 60)...(120 * 60)
    /// Opening LampMaster's card asks for a fresh round when the last one is
    /// older than this.
    public static let openedRefresh: TimeInterval = 15 * 60
    /// About twenty-five rounds at the 4 October measurement of 7.1k tokens a
    /// round: twice what an hourly round spends in a working day.
    public static let dailyTokenCap = 200_000

    public enum Trigger: String, Sendable, Equatable, Codable {
        /// The hourly timer.
        case timer
        /// The user opened LampMaster's card.
        case opened
        /// Asked for in so many words: a menu entry, or the local server.
        case asked
    }

    public enum Skip: String, Sendable, Equatable, Codable {
        case off
        /// No session worth a look.
        case empty
        /// The frame says what it said at the last round.
        case unchanged
        /// The day's tokens are spent.
        case dailyCap
    }

    public enum Decision: Sendable, Equatable {
        /// Not yet time: nothing to record.
        case wait
        case skip(Skip)
        case run
    }

    /// - Parameters:
    ///   - lastRun: when a round last reached `claude`, failed or not. A failed
    ///     round counts, or a broken `claude` would be retried every minute.
    ///   - lastDigest: the digest of that round's frame.
    public static func decide(
        trigger: Trigger, enabled: Bool, interval: TimeInterval, lastRun: Date?, lastDigest: String?,
        digest: String, sessionCount: Int, tokensToday: Int, cap: Int = dailyTokenCap, now: Date
    ) -> Decision {
        guard enabled else { return .skip(.off) }
        let since = lastRun.map { now.timeIntervalSince($0) } ?? .infinity
        switch trigger {
        case .timer where since < clamp(interval): return .wait
        case .opened where since < openedRefresh: return .wait
        default: break
        }
        if sessionCount == 0 { return .skip(.empty) }
        if digest == lastDigest { return .skip(.unchanged) }
        if tokensToday >= cap { return .skip(.dailyCap) }
        return .run
    }

    public static func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// What the round would be told about the sessions, without the minutes.
    ///
    /// The minutes since the last activity change every minute and mean
    /// nothing new by themselves; when they cross a threshold that matters, a
    /// signal appears, and the signal is in the digest.
    public static func digest(_ frame: LampMasterFrame) -> String {
        let timeless = frame.sessions.map { session -> LampMasterFrame.Session in
            var copy = session
            copy.quietMinutes = 0
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(timeless)) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
