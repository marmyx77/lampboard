import Foundation

/// The prompt cache's minutes on a row that waits for the person (UX §4, R3b):
/// answered while it is warm, the next reply reads the conversation back cheaply;
/// once it has gone cold, it is written again in full. From the transcript's own
/// account of how the cache was written, never from a guessed lifetime.
public enum CacheClock {

    /// Minutes left, rounded up; `nil` once cold, or when nothing says how long it lives.
    public static func minutesLeft(_ reading: ContextReading?, now: Date) -> Int? {
        guard let reading, let lifetime = reading.cacheLifetime, let since = reading.cacheAt else { return nil }
        let left = since.addingTimeInterval(lifetime).timeIntervalSince(now)
        guard left > 0 else { return nil }
        return Int((left / 60).rounded(.up))
    }
}
