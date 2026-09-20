import Foundation

/// Everything a row can say about itself, as fields rather than as a paragraph.
///
/// WHY THIS IS A TYPE AND NOT A STRING
/// The tooltip used to be built inside the view, by appending sentences to an
/// array and joining them with newlines. Two things were wrong with that. The
/// small one: everything came out in the same voice — the identity, the figure
/// that moves while you work, and the keyboard help you read once — so the eye
/// had nothing to hold on to. The large one: it lived in a `private var` on a
/// SwiftUI view, which no test in this project can call. What the row tells you
/// is domain, not drawing, and it belongs where it can be checked.
///
/// The view that draws this decides nothing except how it looks.
public struct RowSummary: Sendable, Equatable {

    /// One line of the grid: a label nobody reads twice, and a value they do.
    public struct Field: Sendable, Equatable {
        public let label: String
        public let value: String
        /// The part that is true but secondary — the tokens behind a percentage,
        /// the command behind a slot. Drawn smaller, on the same line.
        public let detail: String?
        /// `0...1` for the one field that has a shape: how full the context is.
        /// Everything else is `nil`, and the view draws no bar for it.
        public let fill: Double?

        public init(_ label: String, _ value: String, detail: String? = nil, fill: Double? = nil) {
            self.label = label
            self.value = value
            self.detail = detail
            self.fill = fill
        }
    }

    /// The name on the row, without the machine — that moves to the subtitle,
    /// where there is room for the word "on".
    public let title: String
    public let status: SessionStatus
    /// Where it is and what it really is: the host, and the folder underneath a
    /// name the user chose. `nil` when the title already says everything.
    public let subtitle: String?
    public let fields: [Field]
    /// One entry per session when the row is a group, most urgent first.
    public let sessions: [String]
    /// The last thing said, or the error that ended the turn.
    public let message: String?
    public let messageIsError: Bool
    /// A standing condition of this row — muted notifications — as opposed to
    /// something that just happened.
    public let notice: String?
    public let keys: String

    // MARK: - Composition

    /// Builds the summary of a row.
    ///
    /// - Parameter revealable: whether the folder can be opened here. A session
    ///   on another machine has a path, and it is not a path on this one.
    public static func of(
        _ row: ColumnRow,
        now: Date,
        muted: Bool = false,
        revealable: Bool = true,
        calendar: Calendar = .current
    ) -> RowSummary {
        var fields: [Field] = [
            Field("activity", RelativeTime.spelled(for: row.updatedAt, now: now, calendar: calendar))
        ]

        // The figure that moves while you work, and the only one here that can be
        // wrong in a way that matters: the label carries its own `≥` or `—`.
        if let context = row.context {
            fields.append(Field("context", context.label, detail: reason(for: context), fill: context.fraction))
            fields.append(Field("model", context.model))
        } else {
            // Never blank. A row with no reading is not a row with room.
            fields.append(Field("context", "—", detail: "nothing read from this session yet"))
        }

        // The question itself, right under the figure, because an amber row is the
        // only kind anybody is reading this card in a hurry to resolve.
        if let ask = row.primary.pendingAsk {
            fields.append(Field("asking", ask.sentence))
        }

        // What this harness cannot tell you, said once, on every row that belongs
        // to it. It is the difference between a limit somebody is told and a limit
        // somebody discovers by trusting a green row that was never going to turn
        // red. Claude Code has nothing to say here and says nothing.
        if let limitation = row.primary.harness.limitation {
            fields.append(Field("harness", row.primary.harness.displayName, detail: limitation))
        }

        // A blue row has to say what is holding it, or a wait that lasts a day is
        // indistinguishable from a defect. A ringed row has to say it for the
        // opposite reason: the ring is deliberately quiet, so this is the only
        // place that can name what is still listening.
        let waiting = counted(row.primary.waitingOn)
        if !waiting.isEmpty {
            fields.append(Field(row.status == .waiting ? "waiting on" : "listening", waiting))
        }

        if row.activeSubagents > 0 {
            fields.append(Field("subagents", "\(row.activeSubagents) at work"))
        }

        // Above the slot and below the harness: it says *where the work is*, which
        // is the same kind of fact as the folder, and it belongs near it. Only
        // drawn when the script could resolve it — a session outside a repository
        // has no line here rather than a line saying so.
        if let git = row.primary.git?.summary {
            fields.append(Field("git", git, detail: detail(forWorktree: row.primary.git?.isWorktree == true)))
        }

        if row.count > 1 {
            fields.append(Field("sessions", "\(row.count) in this project"))
        }

        if let slot = row.slot {
            fields.append(Field("slot", "\(slot)", detail: "lampboard open \(slot)"))
        }

        if row.status == .failed, let reason = row.primary.failureReason {
            fields.append(Field("ended", reason.detailedLabel))
        }

        return RowSummary(
            title: row.displayName,
            status: row.status,
            subtitle: subtitle(of: row),
            fields: fields,
            // Named, not just counted. Three states with nothing attached to
            // them was a list you could read and not use: it said something here
            // is waiting and left you to guess which conversation it was.
            sessions: row.count > 1
                ? row.members.prefix(8).map { "\($0.name) · \($0.session.status.label)" }
                    + (row.count > 8 ? ["…and \(row.count - 8) more"] : [])
                : [],
            message: row.primary.lastMessage,
            messageIsError: row.status == .failed,
            notice: muted ? "Alerts are off for this project." : nil,
            keys: keys(revealable: revealable && !row.workspace.isRemote)
        )
    }

    // MARK: - Pieces

    /// What sits beside the figure, and what sits there instead of one.
    ///
    /// A reading that has been invalidated must not show its tokens. `412,117 of
    /// 1,000,000` beside a dash reads as a figure with a typo in front of it —
    /// and it is not a figure at all: the session was compacted after that reply,
    /// so the number describes a conversation that no longer exists.
    private static func reason(for context: ContextReading) -> String {
        switch context.confidence {
        case .unknown:
            return "the session was compacted since that reading"
        case .exact, .floor:
            guard let window = context.window else {
                return "\(context.tokens.formatted()) tokens · no window recorded for this model"
            }
            return "\(context.tokens.formatted()) of \(window.formatted())"
        case .declared:
            // The window came from the harness, in the same record as the count.
            // Saying so is the point: everywhere else the denominator is ours and
            // could go stale without warning, and here it cannot.
            guard let window = context.window else {
                return "\(context.tokens.formatted()) tokens"
            }
            return "\(context.tokens.formatted()) of \(window.formatted()) · window stated by the harness"
        }
    }

    /// Where it is, and what it is called underneath.
    ///
    /// The folder matters only when the row carries a name the user gave it: with
    /// no alias the title *is* the folder, and repeating it would be a line that
    /// says nothing. When there is one, this is the only place on screen that
    /// says where the session is actually working.
    private static func subtitle(of row: ColumnRow) -> String? {
        var parts: [String] = []
        if let host = row.workspace.host { parts.append("on \(host)") }
        if row.alias != nil { parts.append("in \(row.workspace.name)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `monitor ×2, shell` — in the order they were registered, counted.
    private static func counted(_ types: [String]) -> String {
        let counts = types.reduce(into: [(String, Int)]()) { totals, type in
            if let index = totals.firstIndex(where: { $0.0 == type }) {
                totals[index].1 += 1
            } else {
                totals.append((type, 1))
            }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
    }

    /// The help line: only what this row can actually do.
    ///
    /// A modifier listed here that does nothing when pressed is worse than one
    /// nobody knows about, so a session on another machine does not promise a
    /// folder this Mac cannot open. The drag handle is not named at all: it is
    /// drawn on every row, and a line explaining a thing you can see is the kind
    /// of help that pushes the figure people came for onto the next line.
    private static func keys(revealable: Bool) -> String {
        var parts = ["click opens", "⌘ conversations", "⌥ keeps the green"]
        if revealable { parts.append("⇧ folder") }
        return parts.joined(separator: " · ")
    }
    /// Why a worktree is worth saying in words.
    ///
    /// It changes what the repository **name** means: for a linked worktree the
    /// name is the main repository's, not the folder the session is sitting in, so
    /// somebody comparing the row against their shell would otherwise find two
    /// different names for what they think is one place.
    private static func detail(forWorktree isWorktree: Bool) -> String? {
        isWorktree ? "a linked worktree; the name is the main repository's" : nil
    }

}
