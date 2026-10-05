import Foundation

/// The week in a paragraph (0.7): how many prompts the person typed, in which
/// conversations and projects, on how many days, and what the busiest
/// conversations were called. From the search index's prompts, so it costs no
/// token; and shown only to the person — the bar, the terminal — never to a
/// session.
public enum WeekSummary {

    /// One prompt the person typed: the index's `user` message, with its
    /// conversation's folder and name.
    public struct Prompt: Sendable, Equatable {
        public let sessionId: String
        public let cwd: String?
        public let title: String?
        public let at: Date

        public init(sessionId: String, cwd: String?, title: String?, at: Date) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.title = title
            self.at = at
        }
    }

    public struct Project: Sendable, Equatable {
        public let name: String
        public let prompts: Int
        public let conversations: Int
        public let days: Int
        /// Every titled conversation, the busiest first.
        public let titles: [String]
    }

    public struct Day: Sendable, Equatable {
        public let day: Date
        public let prompts: Int
    }

    public struct Summary: Sendable, Equatable {
        public let from: Date
        public let to: Date
        public let prompts: Int
        public let conversations: Int
        public let activeDays: Int
        /// The busiest project first.
        public let projects: [Project]
        public let busiest: Day?
    }

    /// Seven calendar days, today included.
    public static let days = 7
    static let projectsShown = 8
    static let titlesShown = 3
    static let titleLength = 60
    static let projectLength = 40

    /// Where the week starts: midnight six days before `now`, in `calendar`.
    public static func start(now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
    }

    public static func summarize(_ all: [Prompt], now: Date, calendar: Calendar = .current) -> Summary {
        let from = start(now: now, calendar: calendar)
        let prompts = all.filter { $0.at >= from && $0.at <= now }
        // By folder, not by name: two `api` folders are two projects.
        let byFolder = Dictionary(grouping: prompts) { $0.cwd ?? "" }
        let names = names(of: Array(byFolder.keys))
        let projects = byFolder.map { folder, prompts in
            Project(name: names[folder] ?? "no folder", prompts: prompts.count,
                    conversations: Set(prompts.map(\.sessionId)).count,
                    days: Set(prompts.map { calendar.startOfDay(for: $0.at) }).count,
                    titles: titles(prompts))
        }.sorted { ($0.prompts, $1.name) > ($1.prompts, $0.name) }
        let byDay = Dictionary(grouping: prompts) { calendar.startOfDay(for: $0.at) }
        // The most prompts; between equals, the most recent day.
        let busiest = byDay.map { Day(day: $0.key, prompts: $0.value.count) }
            .max { ($0.prompts, $0.day) < ($1.prompts, $1.day) }
        return Summary(from: from, to: now, prompts: prompts.count,
                       conversations: Set(prompts.map(\.sessionId)).count,
                       activeDays: byDay.count, projects: projects, busiest: busiest)
    }

    public static func text(_ summary: Summary, calendar: Calendar = .current) -> String {
        guard summary.prompts > 0 else { return "Nothing this week: no prompt in the last seven days." }
        let date = formatter("MMM d", calendar), weekday = formatter("EEEE", calendar)
        var head = "This week (\(date.string(from: summary.from)) – \(date.string(from: summary.to))): "
            + "\(count(summary.prompts, "prompt")) in \(count(summary.conversations, "conversation")), "
            + "\(count(summary.projects.count, "project")), \(count(summary.activeDays, "day"))."
        if summary.activeDays > 1, let busiest = summary.busiest {
            head += " Busiest: \(weekday.string(from: busiest.day)), \(count(busiest.prompts, "prompt"))."
        }
        var lines = [head]
        for project in summary.projects.prefix(projectsShown) {
            var line = "\(project.name) · \(count(project.prompts, "prompt")), "
                + "\(count(project.conversations, "conversation")), \(count(project.days, "day"))"
            let named = project.titles.prefix(titlesShown).map { "\u{201C}\($0)\u{201D}" }
            if !named.isEmpty {
                let more = project.titles.count - named.count
                line += ": " + named.joined(separator: ", ") + (more > 0 ? ", and \(more) more" : "")
            }
            lines.append(line)
        }
        let hidden = summary.projects.count - projectsShown
        if hidden > 0 { lines.append("and \(count(hidden, "more project"))") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parts

    /// Each folder's last component, on one line since another session chose
    /// it; with the one above it when two folders end the same way.
    static func names(of folders: [String]) -> [String: String] {
        func last(_ folder: String, _ count: Int) -> String {
            let parts = folder.split(separator: "/").suffix(count).joined(separator: "/")
            let name = LampMasterLookup.clean(parts, to: projectLength)
            return name.isEmpty ? "no folder" : name
        }
        let short = Dictionary(grouping: folders) { last($0, 1) }
        return Dictionary(uniqueKeysWithValues: folders.map { folder in
            (folder, (short[last(folder, 1)]?.count ?? 0) > 1 && !folder.isEmpty ? last(folder, 2) : last(folder, 1))
        })
    }

    /// The titled conversations of a project, the one with most prompts first.
    static func titles(_ prompts: [Prompt]) -> [String] {
        let bySession = Dictionary(grouping: prompts, by: \.sessionId)
        return bySession.values
            .compactMap { prompts -> (title: String, prompts: Int)? in
                let title = LampMasterLookup.clean(prompts.compactMap(\.title).last ?? "", to: titleLength)
                return title.isEmpty ? nil : (title, prompts.count)
            }
            .sorted { ($0.prompts, $1.title) > ($1.prompts, $0.title) }
            .map(\.title)
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
