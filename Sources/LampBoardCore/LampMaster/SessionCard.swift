import Foundation

/// What LampMaster knows about one conversation, read from its transcript.
///
/// WHY A CARD AND NOT THE TRANSCRIPT
/// LampMaster looks at every session once an hour with a real model, and a
/// transcript is tens of megabytes. What it needs to cross sessions is small and
/// specific: what the user last asked, what the session last answered, which
/// files it wrote, what failed and what got saved. Measured on 4 October 2026,
/// eight conversations fit in about 2,500 tokens this way.
///
/// The card is filled incrementally by `SessionCardReader`, the same way the
/// chat window reads a transcript: only what arrived since last time.
public struct SessionCard: Sendable, Equatable {

    /// A file the session wrote, and when.
    public struct Write: Sendable, Equatable {
        public let path: String
        public let at: Date
    }

    /// A tool call that came back as an error.
    public struct Failure: Sendable, Equatable {
        public let tool: String
        /// The error with its paths, numbers and hashes taken out, so the same
        /// failure twice reads the same. See `FailureFingerprint`.
        public let fingerprint: String
        public let at: Date
    }

    /// Something the session saved or proved: the evidence that work is done.
    public struct Milestone: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable, Codable {
            case commit, merge, push, pullRequest, testsPassed, testsFailed
        }
        public let kind: Kind
        public let at: Date
    }

    public let sessionId: String
    public internal(set) var title: String?
    public internal(set) var cwd: String?
    public internal(set) var model: String?
    /// Tokens the last answer was given: input plus both kinds of cache.
    public internal(set) var contextTokens: Int = 0
    public internal(set) var lastActivity: Date?
    /// The user's last prompts, oldest first, at most `SessionCardReader.promptsKept`.
    public internal(set) var recentPrompts: [String] = []
    public internal(set) var lastPromptAt: Date?
    public internal(set) var lastAnswer: String?
    public internal(set) var lastAnswerAt: Date?
    public internal(set) var writes: [Write] = []
    public internal(set) var failures: [Failure] = []
    public internal(set) var milestones: [Milestone] = []

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    /// Distinct files written since `date`, most written first.
    public func filesWritten(since date: Date) -> [String] {
        var counts: [String: Int] = [:]
        for write in writes where write.at >= date { counts[write.path, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Failures since `date`.
    public func failures(since date: Date) -> [Failure] {
        failures.filter { $0.at >= date }
    }

    /// The last milestone after the last prompt: the session saved or proved
    /// something since it was last asked for anything.
    public var milestoneSinceLastPrompt: Milestone? {
        guard let last = milestones.last else { return nil }
        guard let prompt = lastPromptAt else { return last }
        return last.at >= prompt ? last : nil
    }

    /// Whether the last answer reads as a question or a request to the user.
    ///
    /// A heuristic, and labelled as one where it is shown: the hourly round asks
    /// the model to confirm it. Only the end of the answer counts, because a
    /// question asked in passing and then answered is not waiting on anybody.
    public var lastAnswerAsks: Bool {
        guard let answer = lastAnswer?.trimmed.nilIfEmpty else { return false }
        let tail = String(answer.suffix(240)).lowercased()
        if tail.contains("?") { return true }
        return Self.requestMarkers.contains { tail.contains($0) }
    }

    /// Phrases that end an answer by handing the next step to the user.
    ///
    /// English only, and short on purpose: the question mark carries most of the
    /// weight in every language, and what this misses the hourly round reads in
    /// the answer itself. Measured on 4 October 2026, the round caught an Italian
    /// "write «install» when you want" that no list here would have.
    static let requestMarkers = [
        "let me know", "tell me", "when you want", "do you want", "shall i", "should i",
    ]
}
