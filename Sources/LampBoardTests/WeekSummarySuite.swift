import LampBoardCore
import Foundation
import TestKit

/// The week in a paragraph (0.7): what the person asked, where, on which days,
/// from the search index and without a token.
enum WeekSummarySuite {

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Sunday 4 October 2026, 18:00 UTC: the week runs Monday 28 September to today.
    private static let now = Date(timeIntervalSince1970: 1_791_136_800)
    private static func at(daysAgo: Double, hour: Double = 0) -> Date {
        now.addingTimeInterval(-daysAgo * 86_400 + hour * 3600)
    }

    private static func prompt(_ sid: String, _ cwd: String?, _ title: String?, _ at: Date) -> WeekSummary.Prompt {
        WeekSummary.Prompt(sessionId: sid, cwd: cwd, title: title, at: at)
    }

    private static let week: [WeekSummary.Prompt] = [
        prompt("s1", "/home/dev/events", "Slots rename", at(daysAgo: 0)),
        prompt("s1", "/home/dev/events", "Slots rename", at(daysAgo: 0, hour: -1)),
        prompt("s1", "/home/dev/events", "Slots rename", at(daysAgo: 2)),
        prompt("s2", "/home/dev/events", "Docs build fix", at(daysAgo: 2)),
        prompt("s3", "/home/dev/api", nil, at(daysAgo: 5)),
        // Before the week: not counted.
        prompt("s4", "/home/dev/api", "Old work", at(daysAgo: 9)),
    ]

    static let suite = TestSuite("The week, summed up", [

        TestCase("Prompts, conversations, projects and days of the last seven, the older ones out") { t in
            let summary = WeekSummary.summarize(week, now: now, calendar: utc)
            t.expectEqual(summary.prompts, 5)
            t.expectEqual(summary.conversations, 3)
            t.expectEqual(summary.activeDays, 3)
            t.expectEqual(summary.projects.map(\.name), ["events", "api"], "the busiest project first")
            t.expectEqual(summary.projects.first?.prompts, 4)
            t.expectEqual(summary.projects.first?.conversations, 2)
            t.expectEqual(summary.projects.first?.days, 2)
            t.expectEqual(summary.projects.first?.titles, ["Slots rename", "Docs build fix"], "the busiest conversation first")
            t.expectEqual(summary.projects.last?.titles, [], "an untitled conversation counts but is not named")
            t.expectEqual(summary.busiest?.prompts, 2)
        },

        TestCase("The week starts at midnight six days ago, in the person's calendar") { t in
            let edge = utc.startOfDay(for: at(daysAgo: 6))
            let summary = WeekSummary.summarize([
                prompt("a", "/x/in", "In", edge),
                prompt("b", "/x/out", "Out", edge.addingTimeInterval(-1)),
                prompt("c", "/x/later", "Later", now.addingTimeInterval(60)),
            ], now: now, calendar: utc)
            t.expectEqual(summary.projects.map(\.name), ["in"], "the first second counts, the one before and the future do not")
            t.expectEqual(summary.from, edge)
        },

        TestCase("Said in a paragraph a person reads at a glance") { t in
            let text = WeekSummary.text(WeekSummary.summarize(week, now: now, calendar: utc), calendar: utc)
            t.expect(text.hasPrefix("This week (Sep 28 – Oct 4): 5 prompts in 3 conversations, 2 projects, 3 days."), text)
            t.expect(text.contains("Busiest: Sunday, 2 prompts."), text)
            t.expect(text.contains("events · 4 prompts, 2 conversations, 2 days: \u{201C}Slots rename\u{201D}, \u{201C}Docs build fix\u{201D}"), text)
            t.expect(text.contains("api · 1 prompt, 1 conversation, 1 day"), text)
            t.expect(!text.contains("Old work"), "nothing from before the week")
        },

        TestCase("A quiet week says so, and a crowded one says how many more") { t in
            t.expectEqual(WeekSummary.text(WeekSummary.summarize([], now: now, calendar: utc), calendar: utc),
                          "Nothing this week: no prompt in the last seven days.")
            let many = (1...12).flatMap { project in
                (1...4).map { conversation in
                    prompt("p\(project)c\(conversation)", "/w/project\(project)", "Task \(conversation)", at(daysAgo: 1))
                }
            }
            let text = WeekSummary.text(WeekSummary.summarize(many, now: now, calendar: utc), calendar: utc)
            t.expect(text.contains("and 1 more"), "past three titles: \(text)")
            t.expect(text.contains("and 4 more projects"), "past eight projects: \(text)")
        },

        TestCase("The busiest day is the one with most prompts, the most recent only between equals") { t in
            let summary = WeekSummary.summarize([
                prompt("a", "/x/p", "A", at(daysAgo: 4)), prompt("a", "/x/p", "A", at(daysAgo: 4, hour: 1)),
                prompt("a", "/x/p", "A", at(daysAgo: 4, hour: 2)), prompt("b", "/x/p", "B", at(daysAgo: 1)),
            ], now: now, calendar: utc)
            t.expectEqual(summary.busiest?.prompts, 3)
            t.expectEqual(summary.busiest?.day, utc.startOfDay(for: at(daysAgo: 4)), "the older, busier day")
        },

        TestCase("Across the change of hour the week still starts at midnight") { t in
            var rome = Calendar(identifier: .gregorian)
            rome.timeZone = TimeZone(identifier: "Europe/Rome")!
            // Thursday 29 October 2026, noon in Rome: the clocks went back on Sunday the 25th.
            let after = Date(timeIntervalSince1970: 1_793_271_600)
            let start = WeekSummary.start(now: after, calendar: rome)
            t.expectEqual(rome.dateComponents([.day, .hour, .minute], from: start), DateComponents(day: 23, hour: 0, minute: 0))
        },

        TestCase("Two folders with the same name are two projects, told apart by the folder above") { t in
            let summary = WeekSummary.summarize([
                prompt("a", "/work/shop/api", "Shop", at(daysAgo: 1)),
                prompt("b", "/work/bank/api", "Bank", at(daysAgo: 1)),
                prompt("b", "/work/bank/api", "Bank", at(daysAgo: 1, hour: 1)),
            ], now: now, calendar: utc)
            t.expectEqual(summary.projects.map(\.name), ["bank/api", "shop/api"])
        },

        TestCase("A title or a folder another session wrote stays on its line") { t in
            let loud = prompt("z", "/w/odd\nname", "Line one\nLine two " + String(repeating: "y", count: 200), at(daysAgo: 1))
            let text = WeekSummary.text(WeekSummary.summarize([loud], now: now, calendar: utc), calendar: utc)
            t.expectEqual(text.split(separator: "\n").count, 2, text)
            t.expect(text.count < 260, "clipped: \(text.count)")
            let nowhere = WeekSummary.summarize([prompt("n", nil, "Somewhere", at(daysAgo: 1))], now: now, calendar: utc)
            t.expectEqual(nowhere.projects.map(\.name), ["no folder"])
        },
    ])
}
