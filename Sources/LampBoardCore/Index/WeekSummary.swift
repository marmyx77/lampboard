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

    /// One line of an answer: when a session last spoke before the person's
    /// next prompt (R5).
    public struct Answer: Sendable, Equatable {
        public let sessionId: String
        public let at: Date

        public init(sessionId: String, at: Date) {
            self.sessionId = sessionId
            self.at = at
        }
    }

    /// One figure of the week, for the bar's tiles.
    public struct Tile: Sendable, Equatable {
        public let label: String
        public let value: String
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
        /// How long sessions waited on the person: from an answer to the next
        /// prompt in that conversation, an absence over `awayAfter` left out.
        public let waitingOnYou: TimeInterval
    }

    /// Past this, a gap between an answer and the next prompt is the person
    /// away, not the session waiting on them.
    public static let awayAfter: TimeInterval = 4 * 3600

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

    public static func summarize(_ all: [Prompt], answers: [Answer] = [], now: Date,
                                 calendar: Calendar = .current) -> Summary {
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
                       activeDays: byDay.count, projects: projects, busiest: busiest,
                       waitingOnYou: waiting(prompts: all, answers: answers, from: from, now: now))
    }

    /// For each prompt of the week, the time since the last answer that came
    /// after the prompt before it, in that conversation.
    static func waiting(prompts: [Prompt], answers: [Answer], from: Date, now: Date) -> TimeInterval {
        let answered = Dictionary(grouping: answers, by: \.sessionId).mapValues { $0.map(\.at).sorted() }
        var total: TimeInterval = 0
        for (sid, asked) in Dictionary(grouping: prompts, by: \.sessionId) {
            guard let said = answered[sid] else { continue }
            var previous = Date.distantPast
            for prompt in asked.map(\.at).sorted() {
                defer { previous = prompt }
                guard prompt >= from, prompt <= now,
                      let last = said.last(where: { $0 > previous && $0 < prompt }) else { continue }
                let gap = prompt.timeIntervalSince(last)
                if gap <= awayAfter { total += gap }
            }
        }
        return total
    }

    /// The week's figures as tiles; none for an empty week.
    public static func tiles(_ summary: Summary, calendar: Calendar = .current) -> [Tile] {
        guard summary.prompts > 0 else { return [] }
        var tiles = [
            Tile(label: "prompts", value: "\(summary.prompts)"),
            Tile(label: "conversations", value: "\(summary.conversations)"),
            Tile(label: "projects", value: "\(summary.projects.count)"),
            Tile(label: "days", value: "\(summary.activeDays)"),
        ]
        if let busiest = summary.busiest {
            tiles.append(Tile(label: "busiest", value: formatter("EEEE", calendar).string(from: busiest.day)))
        }
        if summary.waitingOnYou >= 60 {
            tiles.append(Tile(label: "waited on you", value: duration(summary.waitingOnYou)))
        }
        return tiles
    }

    /// `39m`, `2h`, `3h 20m`.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
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
        if summary.waitingOnYou >= 60 {
            head += " Sessions waited on you \(duration(summary.waitingOnYou))."
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
