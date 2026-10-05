import LampBoardCore
import Foundation
import TestKit

/// When the five-hour window runs out at the pace of the last hour (§5.2, G2), and
/// whether that is before it resets.
enum AllowanceForecastSuite {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func sample(minutesAgo: Double, _ percent: Int) -> AllowanceForecast.Sample {
        AllowanceForecast.Sample(at: now.addingTimeInterval(-minutesAgo * 60), percent: percent)
    }

    static let suite = TestSuite("Allowance forecast", [

        TestCase("At the last hour's pace, the window runs out when the line reaches a hundred") { t in
            // 40% → 60% in forty minutes: half a percent a minute, eighty minutes to go.
            let samples = [sample(minutesAgo: 40, 40), sample(minutesAgo: 20, 50), sample(minutesAgo: 0, 60)]
            let out = AllowanceForecast.runsOut(samples, now: now)
            t.expectEqual(out.map { Int($0.timeIntervalSince(now) / 60) }, 80)
        },

        TestCase("No forecast from too little: one reading, ten minutes, a flat or falling line") { t in
            t.expectNil(AllowanceForecast.runsOut([sample(minutesAgo: 0, 50)], now: now))
            t.expectNil(AllowanceForecast.runsOut([sample(minutesAgo: 5, 40), sample(minutesAgo: 0, 50)], now: now), "five minutes")
            t.expectNil(AllowanceForecast.runsOut([sample(minutesAgo: 30, 50), sample(minutesAgo: 0, 50)], now: now), "flat")
        },

        TestCase("A reset starts the history again; readings older than an hour are not the pace") { t in
            // 90% an hour and a half ago, then a reset to 5%, then 5% → 25% in thirty minutes.
            let samples = [sample(minutesAgo: 90, 90), sample(minutesAgo: 70, 95), sample(minutesAgo: 30, 5), sample(minutesAgo: 0, 25)]
            let out = AllowanceForecast.runsOut(samples, now: now)
            t.expectEqual(out.map { Int($0.timeIntervalSince(now) / 60) }, 112, "75 points at two thirds a minute")
        },

        TestCase("It says so only when the window would run out before it resets") { t in
            let samples = [sample(minutesAgo: 40, 40), sample(minutesAgo: 0, 60)]
            let early = AllowanceForecast.warning(samples, resetsAt: now.addingTimeInterval(3 * 3600), now: now, calendar: utc)
            t.expectEqual(early, "runs out ~09:20, resets 11:00")
            t.expectNil(AllowanceForecast.warning(samples, resetsAt: now.addingTimeInterval(3600), now: now, calendar: utc),
                        "reset first: nothing to say")
            t.expectNil(AllowanceForecast.warning(samples, resetsAt: nil, now: now, calendar: utc), "no reset known")
        },
    ])

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
