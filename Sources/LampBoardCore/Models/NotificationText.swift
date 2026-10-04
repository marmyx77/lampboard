import Foundation

/// What a notification says: what happened, in a line (plan 5.6).
///
/// "docs-site is waiting" sends you to the window to find out what for. The
/// notification can say it — the command waiting for a yes, the question, why a
/// turn died, the first line of the answer — so that some of them are answered
/// by reading.
public enum NotificationText {

    /// The kinds of news a notification is sent for.
    public enum Event: Equatable, Sendable {
        /// Waiting for a person: a permission or a question.
        case waiting
        /// The turn died: rate limit, overload, an error.
        case failed
        /// The turn finished with an answer. Only for those who asked for it.
        case finished
    }

    /// The longest body, so a long command or answer is cut where it says so.
    public static let bodyLimit = 160

    /// The body, never empty: a notification with no text reads as a glitch.
    ///
    /// The last message is used only for a finished turn. A `Notification`
    /// payload carries none, and the row keeps the reply from the turn before
    /// the question, so quoting it for a waiting session presented the previous
    /// answer as the thing being asked about (see `SessionNotifier`).
    public static func body(for event: Event, session: SessionState) -> String {
        switch event {
        case .waiting:
            if let ask = session.pendingAsk { return clipped("Waiting for you · " + ask.sentence) }
            return session.title.map { clipped("Waiting for your answer: " + $0) } ?? "Waiting for your answer."
        case .failed:
            return session.failureReason.map { "The turn ended: " + $0.detailedLabel } ?? "The turn ended with an error."
        case .finished:
            guard let line = firstLine(of: session.lastMessage) else { return "Finished." }
            return clipped("Finished · " + line)
        }
    }

    /// The first line that says something, without Markdown's marks.
    static func firstLine(of text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*->`_ ")) }
            .first { !$0.isEmpty }
    }

    static func clipped(_ text: String) -> String {
        text.count <= bodyLimit ? text : String(text.prefix(bodyLimit - 1)) + "…"
    }
}

extension MenuBarSummary {

    /// The count beside the lamp when the person asked for one: rows that want
    /// them, then rows at work — `2 · 3`. A zero is drawn as a zero, because
    /// "nothing waits, three at work" is the reassuring half of the answer.
    /// Empty when the column is.
    public var counter: String {
        guard !isEmpty else { return "" }
        let wanting = counts.filter { $0.key.clearsOnFocus }.values.reduce(0, +)
        return "\(wanting) · \(counts[.working] ?? 0)"
    }
}
