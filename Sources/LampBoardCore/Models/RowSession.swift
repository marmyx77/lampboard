import Foundation

/// One conversation inside a row, told apart from the others.
///
/// A row is a project (D4, D23), and a project can hold several conversations at
/// once. Until this type existed the column could only say **how many**: three
/// Claude sessions in one folder are identical in every field the panel draws,
/// same window label, same entrypoint, same folder, same slot, and differ only by
/// a UUID nobody sees. That is a count, not an answer to "which one".
public struct RowSession: Sendable, Equatable, Identifiable {

    /// The session's own id: what a click on this line has to open.
    public let id: String

    /// Its place in the row, 1-based, along the order the conversations were
    /// opened. Also its name while it has none of its own.
    public let ordinal: Int

    /// What to call it: its title, or its position until a title exists.
    public let name: String

    /// Everything else about it: state, context, subagents, how long.
    public let session: SessionState

    public init(id: String, ordinal: Int, name: String, session: SessionState) {
        self.id = id
        self.ordinal = ordinal
        self.name = name
        self.session = session
    }
}

extension RowSession {

    /// The conversations of one row, in the order they were opened.
    ///
    /// Deliberately **not** the order of `sessions`, which is most urgent first.
    /// The column does not reorder itself (D23) and neither may the list inside a
    /// row: a line that jumps because a turn finished is the same defect one
    /// level down, and worse there, because the lines sit closer together and a
    /// misclick opens the wrong conversation.
    ///
    /// Ties are broken by id rather than left to the sort. Sessions adopted from
    /// the filesystem in one pass share a timestamp, and an unstable order would
    /// renumber the list between two otherwise identical renders.
    static func list(
        of sessions: [SessionState], in names: [String: String], order: [String] = []
    ) -> [RowSession] {
        // The order the user put them in first, then the order they were opened.
        // A conversation nobody has moved sorts after the ones somebody did, which
        // is what makes a new one arrive at the end instead of in the middle of a
        // list somebody arranged.
        let placed = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let ordered = sessions.sorted { left, right in
            switch (placed[left.id], placed[right.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return left.firstSeenAt == right.firstSeenAt
                    ? left.id < right.id
                    : left.firstSeenAt < right.firstSeenAt
            }
        }

        return ordered.enumerated().map { index, session in
            let ordinal = index + 1
            return RowSession(
                id: session.id,
                ordinal: ordinal,
                name: name(of: session, ordinal: ordinal, names: names),
                session: session
            )
        }
    }

    /// The lines an opened project draws, in the row's order (D190).
    ///
    /// A project shows at most `cap` conversations, so a panel showing one
    /// project does not grow past the screen. The ones the cap leaves out are
    /// only conversations at rest, and the first of those to go are the ones
    /// opened last. Measured on 27 November 2026: seven agents in one project,
    /// and the seventh, not at rest, was the one the cap left out. It had no line
    /// of its own, and the only way to reach it was the project's line, which
    /// reads as a folder. A conversation that works or waits is never left out, even
    /// if that means going over the cap. `all` is the project opened in full,
    /// from its tail line.
    public static func shown(_ members: [RowSession], cap: Int, all: Bool = false) -> [RowSession] {
        guard !all, members.count > cap else { return members }
        let resting = members.filter { $0.session.status == .idle }
        let room = max(0, cap - (members.count - resting.count))
        let kept = Set(resting.prefix(room).map(\.id))
        return members.filter { $0.session.status != .idle || kept.contains($0.id) }
    }

    /// What to call one conversation, in order of how much it was chosen.
    ///
    /// The name you gave **this** conversation first: it is the most specific
    /// thing anybody said about it. Then its own title, which the transcript
    /// writes after the first exchange. Then its position, which is all there is
    /// in the first seconds of a conversation that has not spoken yet.
    ///
    /// There was a fourth, between the title and the position: a name given to
    /// this agent in this project, which every conversation of that agent
    /// inherited. It was removed on the day it was met — renaming one Codex
    /// conversation appeared to rename all of them, because that is exactly what
    /// it did, and the menu offered it one line under the entry that renames a
    /// single conversation. A name that arrives on rows nobody named is worse
    /// than no name at all.
    private static func name(
        of session: SessionState,
        ordinal: Int,
        names: [String: String]
    ) -> String {
        if let own = RowNames.name(ofSession: session.id, in: names) { return own }
        if let title = session.title { return title }
        return "#\(ordinal)"
    }
}
