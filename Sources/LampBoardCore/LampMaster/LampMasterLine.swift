import Foundation

/// What LampMaster's line in the panel and its cards say, decided here so it
/// can be tested: the panel only draws it.
public enum LampMasterLine {

    /// The line under the column. Open suggestions first, because they are the
    /// reason to look; then why there are none, which is never a blank: a line
    /// that says nothing reads as broken.
    ///
    /// - Parameter time: the clock time of a round, as the panel spells it.
    public static func text(
        open: Int, last: LampMasterRound?, running: Bool, time: (Date) -> String
    ) -> String {
        if running { return "LampMaster is looking…" }
        if open > 0 {
            let count = open == 1 ? "1 suggestion" : "\(open) suggestions"
            return last.map { "\(count) · round at \(time($0.at))" } ?? count
        }
        guard let last else { return "LampMaster · no round yet" }
        switch (last.outcome, last.skip, last.failure) {
        case (.skipped, .dailyCap?, _): return "Today's tokens spent · signals only"
        case (.failed, _, let failure?): return "Last round failed: " + reason(failure)
        default: return "Nothing to report · round at \(time(last.at))"
        }
    }

    public static func reason(_ failure: LampMasterRun.Failure) -> String {
        switch failure {
        case .unreadable: return "claude's answer could not be read"
        case .reportedError: return "claude reported an error"
        case .offSchema: return "the answer was not in the expected shape"
        case .timedOut: return "no answer within the time allowed"
        case .notLaunched: return "claude was not found"
        }
    }

    /// The kind as a card's heading.
    public static func title(_ kind: LampMasterAdvice.Suggestion.Kind) -> String {
        switch kind {
        case .cross: return "One session knows what another needs"
        case .stalled: return "Waiting or stuck"
        case .overlap: return "Two sessions on the same work"
        case .closable: return "Done and saved"
        case .precedent: return "Solved before"
        }
    }

    /// An SF Symbol per kind.
    public static func glyph(_ kind: LampMasterAdvice.Suggestion.Kind) -> String {
        switch kind {
        case .cross: return "arrow.left.arrow.right"
        case .stalled: return "hourglass"
        case .overlap: return "square.on.square"
        case .closable: return "checkmark.circle"
        case .precedent: return "clock.arrow.circlepath"
        }
    }

    /// The button for a card's action, or `nil` when there is nothing to press.
    ///
    /// Asking and replying copy the text and open the session: the panel cannot
    /// write into a session yet (that is 0.6), and a copied sentence one paste
    /// away is honest about it. "Hand over" waits for the witness of 0.7 and
    /// opens the session meanwhile.
    public static func button(_ action: LampMasterAdvice.Suggestion.Action) -> String? {
        switch action.kind {
        case .open, .handoff: return "Open"
        case .ask: return action.question == nil ? "Open" : "Open with the question"
        case .reply: return action.question == nil ? "Open" : "Open with the reply"
        case .close: return "End session…"
        case .archive: return "Remove row"
        case .none: return nil
        }
    }

    /// The session an action is about: its target when it names one, else the
    /// first session the suggestion names.
    public static func subject(of suggestion: LampMasterAdvice.Suggestion) -> String? {
        suggestion.action.target ?? suggestion.sessions.first
    }
}
