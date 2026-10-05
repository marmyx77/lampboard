import Foundation

/// The picture LampMaster's hourly round is given: every session worth looking
/// at, compacted, with what is already known worked out.
///
/// WHY A BUDGET
/// The round costs what the frame weighs. Measured on 4 October 2026: eight
/// conversations, 7,600 characters, about 5,600 input tokens with the prompt.
/// At the scale this was designed for, about two dozen sessions across a dozen
/// windows, the same shape stays under the budget; past it, the frame gives up
/// detail on what matters least before it gives up a session.
public struct LampMasterFrame: Encodable, Sendable, Equatable {

    public struct Quota: Encodable, Sendable, Equatable {
        public let account: String
        public let used: Double
        public let resetInMinutes: Int?
        public let runsOutBeforeReset: Bool

        public init(account: String, used: Double, resetInMinutes: Int?, runsOutBeforeReset: Bool) {
            self.account = account
            self.used = used
            self.resetInMinutes = resetInMinutes
            self.runsOutBeforeReset = runsOutBeforeReset
        }
    }

    public struct Session: Encodable, Sendable, Equatable {
        public let id: String
        public let project: String
        public let name: String?
        public let host: String
        public let surface: String?
        public let agent: String
        public let account: String?
        public let state: LampMasterSession.Liveness
        public var quietMinutes: Int
        public let context: String?
        public let model: String?
        public let branch: String?
        public var recentPrompts: [String]?
        public var lastAnswer: String?
        public var answerAsks: Bool?
        public var filesLastHour: [String]?
        public var failuresLastHour: [String]?
        public var savedSinceLastPrompt: SessionCard.Milestone.Kind?
        public let signals: [LampMasterSignal]
        /// `true` when detail was dropped to fit the budget.
        public var compacted: Bool?
    }

    /// A suggestion already shown, and what the user did with it.
    public struct Recent: Encodable, Sendable, Equatable {
        public let key: String
        public let kind: String
        public let outcome: String
        public let minutesAgo: Int

        public init(key: String, kind: String, outcome: String, minutesAgo: Int) {
            self.key = key
            self.kind = kind
            self.outcome = outcome
            self.minutesAgo = minutesAgo
        }
    }

    /// A failure of the last hour and the conversations elsewhere that said its
    /// words (D3): candidates found by searching first, never recalled.
    public struct Precedent: Encodable, Sendable, Equatable {
        public struct Found: Encodable, Sendable, Equatable {
            public let id: String
            public let project: String?
            public let date: String?
            public let snippet: String

            public init(id: String, project: String?, date: String?, snippet: String) {
                self.id = id
                self.project = project
                self.date = date
                self.snippet = snippet
            }
        }
        public let session: String
        public let error: String
        public let found: [Found]

        public init(session: String, error: String, found: [Found]) {
            self.session = session
            self.error = error
            self.found = found
        }
    }

    public let now: String
    public let quota: [Quota]
    public var sessions: [Session]
    public let recent: [Recent]
    public let muted: [String]
    public let notebook: String
    /// Only in the hourly round's frame: what it shows reaches a person, never
    /// a session's context (an `ask_lampmaster` frame has none).
    public var precedents: [Precedent]?

    /// The frame as the round sends it.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A rough token count: about 3.5 characters a token for this mix of JSON,
    /// English and Italian.
    public var estimatedTokens: Int { Int((Double(json().count) / 3.5).rounded(.up)) }
}

/// Builds the frame.
public enum LampMasterFrameBuilder {

    public static let budgetTokens = 12_000
    /// Closed sessions older than this stay out unless they were left asking.
    public static let recentWindow: TimeInterval = 6 * 60 * 60
    /// How far back a session left asking something is still worth a mention.
    public static let leftAskingWindow: TimeInterval = 7 * 24 * 60 * 60

    public static func build(
        sessions: [LampMasterSession], now: Date, quota: [LampMasterFrame.Quota] = [],
        recent: [LampMasterFrame.Recent] = [], muted: [String] = [], notebook: String = "",
        precedents: [LampMasterFrame.Precedent] = [], budgetTokens: Int = budgetTokens
    ) -> LampMasterFrame {
        let signals = LampMasterSignals.evaluate(sessions, now: now)
        let chosen = sessions
            .filter { include($0, now: now) }
            .map { entry(for: $0, signals: signals[$0.card.sessionId] ?? [], now: now) }
            .sorted(by: precedes)

        var frame = LampMasterFrame(
            now: stamp(now), quota: quota, sessions: chosen, recent: recent,
            muted: muted.sorted(), notebook: String(notebook.prefix(1_500)),
            precedents: precedents.isEmpty ? nil : precedents
        )
        fit(&frame, budgetTokens: budgetTokens)
        return frame
    }

    static func include(_ session: LampMasterSession, now: Date) -> Bool {
        let card = session.card
        // A script's `claude -p`, an SDK agent, another tool's observer: the
        // panel's own rule for what is nobody's session holds here too.
        if let entrypoint = card.entrypoint, AppConfig.nonInteractiveEntrypoints.contains(entrypoint) { return false }
        // A live session counts as soon as it has done anything, even before it
        // has said anything: the files it writes are what overlaps are made of.
        if session.liveness != .closed { return card.lastActivity != nil }
        guard card.lastAnswer != nil || !card.recentPrompts.isEmpty else { return false }
        let age = now.timeIntervalSince(card.lastActivity ?? .distantPast)
        return age <= recentWindow || (card.lastAnswerAsks && age <= leftAskingWindow)
    }

    static func entry(for session: LampMasterSession, signals: [LampMasterSignal], now: Date) -> LampMasterFrame.Session {
        let card = session.card
        let hourAgo = now.addingTimeInterval(-3_600)
        let quiet = max(0, Int(now.timeIntervalSince(card.lastActivity ?? now) / 60))
        let window = session.contextWindow ?? LampMasterSignals.defaultWindow
        let files = card.filesWritten(since: hourAgo).map { relative($0, to: card.cwd) }
        let failures = Array(Set(card.failures(since: hourAgo).map(\.fingerprint))).sorted()
        return LampMasterFrame.Session(
            id: session.shortId,
            project: card.cwd.map { ($0 as NSString).lastPathComponent } ?? "?",
            name: card.title, host: session.host, surface: session.surface, agent: session.agent,
            account: session.account, state: session.liveness, quietMinutes: quiet,
            context: card.contextTokens > 0 ? "\(card.contextTokens / 1_000)k/\(window / 1_000)k" : nil,
            model: card.model, branch: session.branch ?? card.gitBranch,
            recentPrompts: card.recentPrompts.isEmpty ? nil : card.recentPrompts,
            lastAnswer: card.lastAnswer, answerAsks: card.lastAnswerAsks ? true : nil,
            filesLastHour: files.isEmpty ? nil : Array(files.prefix(6)),
            failuresLastHour: failures.isEmpty ? nil : Array(failures.prefix(4)),
            savedSinceLastPrompt: card.milestoneSinceLastPrompt?.kind,
            signals: signals, compacted: nil
        )
    }

    /// Sessions with signals first, then the live ones, then the most recent.
    static func precedes(_ a: LampMasterFrame.Session, _ b: LampMasterFrame.Session) -> Bool {
        if a.signals.isEmpty != b.signals.isEmpty { return !a.signals.isEmpty }
        if (a.state == .closed) != (b.state == .closed) { return a.state != .closed }
        if a.quietMinutes != b.quietMinutes { return a.quietMinutes < b.quietMinutes }
        return a.id < b.id
    }

    /// Gives up detail before sessions: first the prompts and answers of quiet,
    /// closed sessions with nothing to say, then whole sessions from the end.
    /// The round's precedents (D3), added once it is known to run: only for
    /// the sessions the frame kept, and gone again if they break the budget.
    public static func add(_ precedents: [LampMasterFrame.Precedent], to frame: inout LampMasterFrame,
                           budgetTokens: Int = budgetTokens) {
        let kept = Set(frame.sessions.map(\.id))
        let mine = precedents.filter { kept.contains($0.session) }
        frame.precedents = mine.isEmpty ? nil : mine
        if frame.estimatedTokens > budgetTokens { frame.precedents = nil }
    }

    static func fit(_ frame: inout LampMasterFrame, budgetTokens: Int) {
        // Candidates go before any session's detail: the sessions are the frame.
        if frame.estimatedTokens > budgetTokens { frame.precedents = nil }
        var index = frame.sessions.count - 1
        while frame.estimatedTokens > budgetTokens, index >= 0 {
            if frame.sessions[index].signals.isEmpty, frame.sessions[index].compacted == nil {
                frame.sessions[index].recentPrompts = frame.sessions[index].recentPrompts.map { Array($0.suffix(1)) }
                frame.sessions[index].lastAnswer = frame.sessions[index].lastAnswer.map { String($0.prefix(120)) }
                frame.sessions[index].filesLastHour = nil
                frame.sessions[index].compacted = true
            }
            index -= 1
        }
        while frame.estimatedTokens > budgetTokens, !frame.sessions.isEmpty {
            frame.sessions.removeLast()
        }
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(cwd.count + 1))
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
