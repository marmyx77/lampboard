import Foundation

/// What the hourly round answers, and the checks it must pass to be shown.
///
/// WHY A VALIDATOR
/// "No invention" was the prototype's best property and it was a hope: the
/// model was told not to invent, and did not. Here it becomes a check. Every
/// suggestion names sessions that are in the frame, and quotes the frame word
/// for word as its evidence; one that does not is dropped before anybody sees
/// it, and the reason is kept so the prompt can be fixed.
public struct LampMasterAdvice: Decodable, Sendable, Equatable {

    public struct Suggestion: Codable, Sendable, Equatable {

        /// LampMaster's five jobs.
        public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
            /// One session knows something another needs now.
            case cross
            /// Waiting on the user, blocked, or left half done.
            case stalled
            /// Two sessions on the same files, branch or problem.
            case overlap
            /// Done and saved: it can be closed.
            case closable
            /// Somebody solved this before.
            case precedent
        }

        public struct Action: Codable, Sendable, Equatable {
            public enum Kind: String, Codable, Sendable, Equatable {
                case open, ask, reply, handoff, close, archive, none
            }
            public let kind: Kind
            public let target: String?
            public let question: String?

            public init(kind: Kind, target: String? = nil, question: String? = nil) {
                self.kind = kind
                self.target = target
                self.question = question
            }
        }

        public let kind: Kind
        public let sessions: [String]
        public let text: String
        public let evidence: String
        public let action: Action
        public let confidence: Double
        /// Stable across rounds for the same situation, so it is never shown twice.
        public let key: String

        public init(
            kind: Kind, sessions: [String], text: String, evidence: String,
            action: Action, confidence: Double, key: String
        ) {
            self.kind = kind
            self.sessions = sessions
            self.text = text
            self.evidence = evidence
            self.action = action
            self.confidence = confidence
            self.key = key
        }
    }

    public let suggestions: [Suggestion]
    public let notebook: String?

    public init(suggestions: [Suggestion], notebook: String? = nil) {
        self.suggestions = suggestions
        self.notebook = notebook
    }

    /// Reads the `structured_output` of a `claude -p --json-schema` result, or
    /// the object itself. Anything else is `nil`: a malformed answer is a
    /// failed round, never a partial one.
    public static func decode(_ data: Data) -> LampMasterAdvice? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (object["structured_output"] as? [String: Any]) ?? object
        guard let inner = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(LampMasterAdvice.self, from: inner)
    }
}

/// The checks between the model and the panel.
public enum LampMasterValidator {

    public enum Rejection: String, Sendable, Equatable {
        case unknownSession, noEvidence, shownRecently, muted, lowConfidence, overLimit
    }

    public static let shownPerRound = 3
    public static let minimumConfidence = 0.5
    public static let minimumQuote = 20
    public static let repeatWindow: TimeInterval = 24 * 60 * 60

    public struct Verdict: Sendable, Equatable {
        public let shown: [LampMasterAdvice.Suggestion]
        public let rejected: [(LampMasterAdvice.Suggestion, Rejection)]

        public init(shown: [LampMasterAdvice.Suggestion], rejected: [(LampMasterAdvice.Suggestion, Rejection)]) {
            self.shown = shown
            self.rejected = rejected
        }

        public static func == (lhs: Verdict, rhs: Verdict) -> Bool {
            lhs.shown == rhs.shown
                && lhs.rejected.map(\.0) == rhs.rejected.map(\.0)
                && lhs.rejected.map(\.1) == rhs.rejected.map(\.1)
        }
    }

    /// - Parameters:
    ///   - frame: the frame the round was given, as sent.
    ///   - ids: the short ids of the sessions in it.
    ///   - shownAt: when each key was last shown.
    public static func screen(
        _ advice: LampMasterAdvice, frame: String, ids: Set<String>, shownAt: [String: Date],
        muted: Set<LampMasterAdvice.Suggestion.Kind>, now: Date
    ) -> Verdict {
        let haystack = normalise(frame)
        var shown: [LampMasterAdvice.Suggestion] = []
        var rejected: [(LampMasterAdvice.Suggestion, Rejection)] = []

        for suggestion in advice.suggestions {
            let named = suggestion.sessions + [suggestion.action.target].compactMap { $0 }
            let rejection: Rejection?
            if suggestion.sessions.isEmpty || named.contains(where: { !ids.contains(String($0.prefix(8))) }) {
                rejection = .unknownSession
            } else if !quotesFrame(suggestion.evidence, haystack: haystack) {
                rejection = .noEvidence
            } else if let last = shownAt[suggestion.key], now.timeIntervalSince(last) < repeatWindow {
                rejection = .shownRecently
            } else if muted.contains(suggestion.kind) {
                rejection = .muted
            } else if suggestion.confidence < minimumConfidence {
                rejection = .lowConfidence
            } else if shown.count >= shownPerRound {
                rejection = .overLimit
            } else {
                rejection = nil
            }
            if let rejection { rejected.append((suggestion, rejection)) } else { shown.append(suggestion) }
        }
        return Verdict(shown: shown, rejected: rejected)
    }

    /// Whether some fragment of the evidence, at least `minimumQuote`
    /// characters long, is in the frame word for word.
    ///
    /// The fragments tried are what sits between quotation marks, everything
    /// between the first mark and the last (a quote that itself quotes, like
    /// `“write «install» when you want”`), and the clauses between `;` and `.`.
    /// Any of them is enough: each must still be twenty characters found word for
    /// word. Spacing, case and the kind of quotation mark do not count: the model
    /// straightens and curls them at will, and a JSON string escapes them.
    static func quotesFrame(_ evidence: String, haystack: String) -> Bool {
        let text = normalise(evidence)
        var fragments = text.components(separatedBy: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
        if let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last {
            fragments.append(String(text[text.index(after: first)..<last]))
        }
        fragments += text.components(separatedBy: CharacterSet(charactersIn: ";."))
        return fragments
            .map { $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
            .contains { $0.count >= minimumQuote && haystack.contains($0) }
    }

    static func normalise(_ text: String) -> String {
        var result = text.lowercased().replacingOccurrences(of: "\\\"", with: "\"")
        for mark in ["«", "»", "“", "”", "„", "‘", "’", "'"] {
            result = result.replacingOccurrences(of: mark, with: "\"")
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
