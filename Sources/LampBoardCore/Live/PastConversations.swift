import Foundation

/// The conversations of a project (hub-terminale R5): its transcripts, the
/// latest first. The ones a process holds now come first and are marked: they
/// are opened where they run, never taken up again, which would make a second
/// writer. Hidden, they read as LampBoard not finding them (13 October 2026:
/// Hermes, running in tmux on the Bestia, was simply missing from the list).
public enum PastConversations {

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let modified: Date
        public let title: String?
        /// A process holds it now: open it, do not take it up.
        public let isLive: Bool

        public init(id: String, modified: Date, title: String?, isLive: Bool = false) {
            self.id = id
            self.modified = modified
            self.title = title
            self.isLive = isLive
        }
    }

    /// The ones `live` holds first, marked, then the latest `limit` of the
    /// rest; none that is not a conversation's id.
    public static func pick(_ items: [Item], live: Set<String>, limit: Int = 15) -> [Item] {
        let ids = items.filter { ModReport.isSessionId($0.id) && $0.id.count == 36 }
            .sorted { $0.modified > $1.modified }
        let running = ids.filter { live.contains($0.id) }
            .map { Item(id: $0.id, modified: $0.modified, title: $0.title, isLive: true) }
        let rest = ids.filter { !live.contains($0.id) }.prefix(limit)
        return running + rest
    }

    /// The transcripts of `folder` in another machine's listing (`RemoteTranscripts`).
    public static func remote(_ files: [RemoteTranscripts.File], folder: String) -> [Item] {
        let prefix = "./" + TranscriptLocator.directoryName(forWorkspace: folder) + "/"
        return files.filter { $0.path.hasPrefix(prefix) }
            .map { Item(id: $0.sessionId, modified: $0.modified, title: nil) }
    }
}

/// The list in «Resume a past conversation…» as the sheet draws it: a row per
/// conversation, in the order `PastConversations.pick` gives, the list as tall
/// as its rows up to `shownRows` and scrolling in that height past them; one
/// row selected, moved with ↑ ↓ and taken up with ⏎.
///
/// The height is computed because it was left to the sheet. A sheet takes the
/// height its content asks for, and a scroll view capped at 280 points asks for
/// almost none: on 14 October 2026 the sheet showed half of the first row, with
/// a scroller a few points tall for the others, and Cancel right under it.
public enum ResumeList {

    /// Rows shown before the list scrolls: a project's busy week, still a sheet
    /// on a laptop's screen.
    public static let shownRows = 8
    /// A row's two lines (title; project and id) and their padding, in points.
    public static let rowHeight: Double = 44
    /// Above the first row and under the last, in points: the selection's
    /// rounded corners are not cut by the list's edge.
    public static let inset: Double = 4
    /// The characters of an id that tell two conversations apart.
    static let idPrefix = 8

    /// One conversation, as its row says it.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        /// One line: the transcript's title, the name of the row running it, or
        /// the start of its id.
        public let title: String
        /// The project, its machine when it is not this Mac, and the start of the
        /// id when the title is not already it: two untitled conversations read apart.
        public let detail: String
        /// `3h`, or «Running now» for one a process holds.
        public let age: String
        /// A process holds it now: opened where it runs, never taken up again.
        public let isLive: Bool
    }

    /// The rows of `items`, in their order. `name` is the row's name of a
    /// conversation running now, when there is a row.
    public static func rows(_ items: [PastConversations.Item], project: String, host: String?,
                            name: (String) -> String?, now: Date) -> [Row] {
        items.map { item in
            let short = String(item.id.prefix(idPrefix))
            let titled = [item.title, name(item.id)].compactMap { $0.map(RowActivity.flat) }.first { !$0.isEmpty }
            let place = project + (host.map { " on \($0)" } ?? "")
            return Row(id: item.id, title: titled ?? short,
                       detail: titled == nil ? place : place + " · " + short,
                       age: item.isLive ? "Running now" : RelativeTime.label(for: item.modified, now: now),
                       isLive: item.isLive)
        }
    }

    /// The list's height for `count` rows: every row up to `shownRows`, then
    /// that many, the rest scrolled to.
    public static func height(rows count: Int) -> Double {
        Double(min(max(count, 0), shownRows)) * rowHeight + 2 * inset
    }

    /// Whether `count` rows need the list to scroll.
    public static func scrolls(rows count: Int) -> Bool { count > shownRows }

    /// The row selected when the list arrives: the first, the one a process
    /// holds or else the latest; none in an empty list.
    public static func firstSelection(count: Int) -> Int? { count > 0 ? 0 : nil }

    /// The selection after ↑ (`-1`) or ↓ (`1`), kept inside the list. With none
    /// selected, ↓ selects the first and ↑ the last.
    public static func move(_ selection: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selection else { return step < 0 ? count - 1 : 0 }
        return CommandBar.move(min(selection, count - 1), by: step, count: count)
    }
}
