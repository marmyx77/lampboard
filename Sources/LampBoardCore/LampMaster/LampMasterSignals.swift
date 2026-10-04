import Foundation

/// A session as LampMaster weighs it: its card, plus what only the panel knows.
public struct LampMasterSession: Sendable, Equatable {

    /// What the panel can say about the process right now.
    public enum Liveness: String, Sendable, Equatable, Codable {
        /// Running a turn.
        case working
        /// Alive and waiting for the user: a permission, a question, a dialog.
        case asking
        /// Alive and done with its turn.
        case idle
        /// No process behind it.
        case closed
    }

    public let card: SessionCard
    public let liveness: Liveness
    /// Where it runs, as the row says it: `mac`, or a node's name.
    public let host: String
    /// Terminal, editor, application, as the row says it.
    public let surface: String?
    public let agent: String
    public let account: String?
    public let repository: String?
    public let branch: String?
    /// The window the model works in, in tokens, when the panel knows it.
    public let contextWindow: Int?

    public init(
        card: SessionCard, liveness: Liveness, host: String = "mac", surface: String? = nil,
        agent: String = "claude-code", account: String? = nil, repository: String? = nil,
        branch: String? = nil, contextWindow: Int? = nil
    ) {
        self.card = card
        self.liveness = liveness
        self.host = host
        self.surface = surface
        self.agent = agent
        self.account = account
        self.repository = repository
        self.branch = branch
        self.contextWindow = contextWindow
    }

    /// The short id LampMaster and its suggestions use: eight characters.
    public var shortId: String { String(card.sessionId.prefix(8)) }
}

/// What can be told about a session without asking any model.
///
/// WHY THEY COME FIRST
/// Noticing costs nothing; thinking costs tokens. Every rule here reads data the
/// panel already has, runs on every change, shows on the row at once, and goes
/// into the hourly round already worked out, so the model spends its tokens on
/// what only a model can tell: whether two things are the same thing.
public enum LampMasterSignal: Hashable, Sendable {
    /// Idle, its last answer asks something, and nobody has answered for a while.
    case waitingOnYou
    /// A turn running with nothing written to the transcript for a while.
    case stuck
    /// The same failure several times in the last hour.
    case repeatedFailure(fingerprint: String)
    /// Wrote a file another session also wrote recently.
    case sameFiles(with: String)
    /// Alive on the same branch of the same repository as another live session.
    case sameBranch(with: String)
    /// Saved or proved its work since it was last asked, asks nothing, and has
    /// been quiet for an hour.
    case finished
    /// Most of its context window is used.
    case contextHigh
}

extension LampMasterSignal: Encodable {

    /// One short phrase per signal: the frame is read by a model, and
    /// `{"sameFiles":{"with":"…"}}` spends tokens to say less.
    public var label: String {
        switch self {
        case .waitingOnYou: return "waiting on the user"
        case .stuck: return "stuck in a turn"
        case .repeatedFailure(let fingerprint): return "same failure repeated: " + fingerprint
        case .sameFiles(let other): return "wrote the same files as " + other
        case .sameBranch(let other): return "same branch as " + other
        case .finished: return "work saved, nothing asked, quiet"
        case .contextHigh: return "context nearly full"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// The thresholds, in one place, and the rules that apply them.
public enum LampMasterSignals {

    public static let waitingAfter: TimeInterval = 20 * 60
    public static let stuckAfter: TimeInterval = 10 * 60
    public static let failureWindow: TimeInterval = 60 * 60
    public static let failuresToRepeat = 3
    public static let overlapWindow: TimeInterval = 2 * 60 * 60
    public static let finishedAfter: TimeInterval = 60 * 60
    public static let contextHighShare = 0.85
    /// Used when the panel does not know the model's window.
    public static let defaultWindow = 200_000

    /// Every signal of every session, keyed by session id.
    public static func evaluate(_ sessions: [LampMasterSession], now: Date) -> [String: [LampMasterSignal]] {
        var result: [String: [LampMasterSignal]] = [:]
        for session in sessions {
            result[session.card.sessionId] = own(session, now: now)
        }
        for (index, session) in sessions.enumerated() {
            for other in sessions[(index + 1)...] {
                for (a, b) in [(session, other), (other, session)] {
                    result[a.card.sessionId, default: []].append(contentsOf: shared(a, b, now: now))
                }
            }
        }
        return result
    }

    /// The signals a session has on its own.
    static func own(_ session: LampMasterSession, now: Date) -> [LampMasterSignal] {
        let card = session.card
        let quiet = now.timeIntervalSince(card.lastActivity ?? now)
        var signals: [LampMasterSignal] = []

        if session.liveness == .idle, card.lastAnswerAsks, quiet >= waitingAfter {
            signals.append(.waitingOnYou)
        }
        if session.liveness == .working, quiet >= stuckAfter {
            signals.append(.stuck)
        }
        let recent = card.failures(since: now.addingTimeInterval(-failureWindow))
        let counts = Dictionary(grouping: recent, by: \.fingerprint).mapValues(\.count)
        for (fingerprint, count) in counts.sorted(by: { $0.key < $1.key })
        where count >= failuresToRepeat && !fingerprint.isEmpty {
            signals.append(.repeatedFailure(fingerprint: fingerprint))
        }
        if session.liveness != .working, session.liveness != .asking, !card.lastAnswerAsks,
           card.milestoneSinceLastPrompt.map({ $0.kind != .testsFailed }) == true,
           quiet >= finishedAfter {
            signals.append(.finished)
        }
        let window = session.contextWindow ?? defaultWindow
        if window > 0, Double(card.contextTokens) >= Double(window) * contextHighShare {
            signals.append(.contextHigh)
        }
        return signals
    }

    /// The signals `a` has because of `b`.
    static func shared(_ a: LampMasterSession, _ b: LampMasterSession, now: Date) -> [LampMasterSignal] {
        var signals: [LampMasterSignal] = []
        let since = now.addingTimeInterval(-overlapWindow)
        let mine = Set(a.card.filesWritten(since: since))
        if !mine.isEmpty, !mine.isDisjoint(with: b.card.filesWritten(since: since)) {
            signals.append(.sameFiles(with: b.shortId))
        }
        if a.liveness != .closed, b.liveness != .closed,
           let repository = a.repository, repository == b.repository,
           let branch = a.branch, branch == b.branch, a.host == b.host {
            signals.append(.sameBranch(with: b.shortId))
        }
        return signals
    }
}
