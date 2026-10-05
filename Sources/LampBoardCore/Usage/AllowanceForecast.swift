import Foundation

/// When the five-hour window runs out at the pace of the last hour (§5.2, G2).
///
/// Only the panel sees every session of an account at once, so only it can say
/// "at this pace you run out at 11:40, and it resets at 13:10". The pace is a
/// straight line through the readings of the last hour since the last reset: an
/// hour is long enough to smooth one busy turn and short enough to notice that
/// three sessions have just started. Too little to fit — under ten minutes, or a
/// line that does not climb — is no forecast, never a guess.
public enum AllowanceForecast {

    public struct Sample: Sendable, Equatable {
        public let at: Date
        public let percent: Int

        public init(at: Date, percent: Int) {
            self.at = at
            self.percent = percent
        }
    }

    /// How far back the pace is read.
    public static let window: TimeInterval = 3600
    /// The least span a line is drawn through.
    static let shortest: TimeInterval = 600

    /// When the count reaches a hundred at the recent pace, or `nil`.
    public static func runsOut(_ samples: [Sample], now: Date) -> Date? {
        let ordered = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        // Since the last reset: a reading lower than the one before it starts again.
        var since = 0
        for index in ordered.indices.dropFirst() where ordered[index].percent < ordered[index - 1].percent { since = index }
        let recent = ordered[since...].filter { now.timeIntervalSince($0.at) <= window }
        guard let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= shortest else { return nil }
        // Least squares, in percent per second.
        let xs = recent.map { $0.at.timeIntervalSince(first.at) }, ys = recent.map { Double($0.percent) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let spread = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        guard spread > 0 else { return nil }
        let slope = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / spread
        guard slope > 0 else { return nil }
        return last.at.addingTimeInterval((100 - Double(last.percent)) / slope)
    }

    /// "runs out ~11:40, resets 13:10" when the window would run out before it
    /// resets; otherwise nothing, since a forecast that changes nothing is noise.
    public static func warning(_ samples: [Sample], resetsAt: Date?, now: Date,
                               calendar: Calendar = .current) -> String? {
        guard let resetsAt, let out = runsOut(samples, now: now), out < resetsAt else { return nil }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"
        return "runs out ~\(clock.string(from: out)), resets \(clock.string(from: resetsAt))"
    }
}
