import LampBoardCore
import Foundation
import TestKit

/// Learning when it matters (U5): a tip the first time something happens, one a
/// day at most, each once; and a catalogue of what LampBoard can do, by what a
/// person wants rather than by component.
enum LearnSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400

    private static func facts(stopped: Bool = false, needsYou: Bool = false, usage: Int? = nil,
                              rows: Int = 2, resting: Bool = false) -> Tips.Facts {
        Tips.Facts(stopped: stopped, needsYou: needsYou, usagePercent: usage, rowCount: rows, resting: resting)
    }

    static let suite = TestSuite("Learning when it matters", [

        TestCase("The first time something happens, its tip; nothing happening, none") { t in
            t.expectNil(Tips.next(facts(), shown: [:], now: t0))
            t.expectEqual(Tips.next(facts(stopped: true), shown: [:], now: t0), .stopped)
            t.expectEqual(Tips.next(facts(usage: 80), shown: [:], now: t0), .usageHigh)
            t.expectNil(Tips.next(facts(usage: 79), shown: [:], now: t0), "below eighty is not news")
            t.expectEqual(Tips.next(facts(resting: true), shown: [:], now: t0), .resting)
            t.expectEqual(Tips.next(facts(rows: 6), shown: [:], now: t0), .manyRows)
        },

        TestCase("Each tip once, ever") { t in
            t.expectNil(Tips.next(facts(stopped: true), shown: [Tips.Tip.stopped.rawValue: t0], now: t0.addingTimeInterval(30 * day)))
        },

        TestCase("One a day at most, whichever it was") { t in
            let shown = [Tips.Tip.stopped.rawValue: t0]
            t.expectNil(Tips.next(facts(needsYou: true), shown: shown, now: t0.addingTimeInterval(day - 60)), "the same day")
            t.expectEqual(Tips.next(facts(needsYou: true), shown: shown, now: t0.addingTimeInterval(day)), .needsYou, "a day later")
        },

        TestCase("Two at once: the one that matters most first") { t in
            t.expectEqual(Tips.next(facts(stopped: true, needsYou: true, usage: 90), shown: [:], now: t0), .needsYou)
        },

        TestCase("Every tip is one sentence the band's two lines can hold") { t in
            for tip in Tips.Tip.allCases { t.expect(tip.text.count <= 90, "\(tip): \(tip.text.count) characters") }
        },

        TestCase("A tip holds while its thing is on screen, and not after") { t in
            t.expect(Tips.holds(.needsYou, facts(needsYou: true)), "asking")
            t.expect(!Tips.holds(.needsYou, facts()), "answered: the tip goes")
            t.expect(!Tips.holds(.usageHigh, facts(usage: 40)), "the window reset")
        },

        TestCase("The catalogue: six groups by what you want, every capability in one of them") { t in
            t.expectEqual(Capabilities.groups.map(\.title), [
                "Answer sooner", "Stay out of trouble", "Spend less", "Work across sessions", "Step away", "Look back and far",
            ])
            let items = Capabilities.groups.flatMap(\.items)
            t.expectEqual(Set(items.map(\.name)).count, items.count, "one name each")
            t.expect(items.allSatisfy { !$0.sentence.isEmpty && $0.sentence.count <= 120 }, "a sentence each, short")
            t.expect(items.allSatisfy { $0.tryIt != nil || $0.setting != nil || !$0.place.isEmpty },
                     "each one can be tried, turned on, or found: \(items.filter { $0.tryIt == nil && $0.setting == nil && $0.place.isEmpty }.map(\.name))")
        },

        TestCase("What needs the helper says so; what turns on points at the setting Settings has") { t in
            let quick = Capabilities.groups.flatMap(\.items).first { $0.name == "Quick answers" }
            t.expectEqual(quick?.needsHelper, true)
            t.expectEqual(quick?.setting, .answerPrompts)
            let alerts = Capabilities.groups.flatMap(\.items).first { $0.name == "Alerts" }
            t.expectEqual(alerts?.needsHelper, false)
            t.expectEqual(alerts?.setting, .notifications)
        },
    ])
}
