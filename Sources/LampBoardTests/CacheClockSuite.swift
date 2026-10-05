import LampBoardCore
import Foundation
import TestKit

/// The prompt cache's minutes on a waiting row (UX §4, R3b): read, not guessed.
/// Each reply's usage says how its cache was written — `ephemeral_5m` or
/// `ephemeral_1h` — and a reply only reading it keeps the lifetime it had.
enum CacheClockSuite {

    static func reply(fiveMinutes: Int = 0, oneHour: Int = 0, read: Int = 40_000, at: String = "2026-10-05T08:00:00.000Z") -> String {
        """
        {"type":"assistant","timestamp":"\(at)","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,\
        "cache_creation_input_tokens":\(fiveMinutes + oneHour),"cache_read_input_tokens":\(read),\
        "cache_creation":{"ephemeral_5m_input_tokens":\(fiveMinutes),"ephemeral_1h_input_tokens":\(oneHour)},"output_tokens":10}}}
        """
    }

    static let at = ISO8601DateFormatter().date(from: "2026-10-05T08:00:00Z")!

    static let suite = TestSuite("The prompt cache's minutes", [

        TestCase("A reply that wrote an hour's cache: an hour from it; five minutes' cache: five") { t in
            t.expectEqual(ContextScanner.read(tail: reply(oneHour: 546))?.cacheLifetime, 3_600)
            t.expectEqual(ContextScanner.read(tail: reply(fiveMinutes: 546))?.cacheLifetime, 300)
        },

        TestCase("A reply that only read the cache keeps the lifetime the last write gave it") { t in
            let tail = reply(oneHour: 546, at: "2026-10-05T07:50:00.000Z") + "\n" + reply(read: 50_000)
            let reading = ContextScanner.read(tail: tail)
            t.expectEqual(reading?.cacheLifetime, 3_600)
            t.expectEqual(reading?.at, at, "counted from the last reply, which refreshed it")
            t.expectNil(ContextScanner.read(tail: reply(read: 50_000))?.cacheLifetime, "never written in sight: not known")
        },

        TestCase("The minutes left, rounded up; none once it has gone cold or when unknown") { t in
            let reading = ContextReading(tokens: 1, model: "m", window: nil, confidence: .exact, at: at, cacheLifetime: 3_600)
            t.expectEqual(CacheClock.minutesLeft(reading, now: at.addingTimeInterval(60 * 17 + 10)), 43)
            t.expectNil(CacheClock.minutesLeft(reading, now: at.addingTimeInterval(3_601)), "cold")
            t.expectNil(CacheClock.minutesLeft(ContextReading(tokens: 1, model: "m", window: nil, confidence: .exact, at: at), now: at))
        },

        TestCase("Shown where the next move is the person's, not while the session works") { t in
            t.expectEqual(Set(SessionStatus.allCases.filter(\.isWaitingOnPerson)), [.ready, .awaiting, .failed, .idle])
            t.expect(!SessionStatus.working.isWaitingOnPerson && !SessionStatus.waiting.isWaitingOnPerson, "its own work")
        },

        TestCase("A measure from the mod keeps the lifetime the transcript gave") { t in
            let previous = ContextReading(tokens: 1, model: "claude-opus-5-5", window: 200_000, confidence: .exact, at: at, cacheLifetime: 3_600)
            let measure = ModReport.Measure(tokens: 2_000, window: 200_000, model: nil, rateLimits: [], costUSD: nil)
            t.expectEqual(measure.reading(previous: previous, at: at)?.cacheLifetime, 3_600)
        },

        TestCase("A reported count, which a transcript reading never replaces, still takes its cache clock") { t in
            let session = SessionState(id: "s1", status: .idle, workspace: Workspace(path: "/home/dev/events"), updatedAt: at, statusSince: at)
            var state = StateReducer.reduce(TrafficLightState(sessions: ["s1": session]),
                                            action: .observed(sessionId: "s1", context: ContextReading(tokens: 9_000, model: "m", window: 200_000, confidence: .reported, at: at)), now: at)
            state = StateReducer.reduce(state, action: .observed(sessionId: "s1", context: ContextReading(
                tokens: 7_000, model: "m", window: 200_000, confidence: .exact, at: at, cacheLifetime: 3_600)), now: at)
            t.expectEqual(state.sessions["s1"]?.context?.tokens, 9_000, "the session's own count stays")
            t.expectEqual(state.sessions["s1"]?.context?.cacheLifetime, 3_600, "with the transcript's cache clock")
        },
    ])
}
