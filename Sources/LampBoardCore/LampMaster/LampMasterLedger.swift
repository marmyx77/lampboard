import Foundation

/// One round, as `rounds.jsonl` keeps it.
///
/// Skips are rounds too: they are how the user learns that LampMaster looked
/// and had nothing to spend tokens on, and how a week of rounds can be read
/// back to see what an hour costs.
public struct LampMasterRound: Codable, Sendable, Equatable {

    public enum Outcome: String, Codable, Sendable, Equatable {
        case ran, skipped, failed
    }

    public let at: Date
    public let trigger: LampMasterSchedule.Trigger
    public let outcome: Outcome
    public let skip: LampMasterSchedule.Skip?
    public let failure: LampMasterRun.Failure?
    public let model: String?
    public let seconds: Double?
    public let tokens: Int
    public let costUSD: Double?
    /// Sessions in the frame, and the frame's estimated size.
    public let sessions: Int
    public let frameTokens: Int?
    public let proposed: Int
    /// Rejections by the validator's reason: the material for a better prompt.
    public let rejected: [String: Int]
    public let shown: Int
    public let digest: String?

    public init(
        at: Date, trigger: LampMasterSchedule.Trigger, outcome: Outcome,
        skip: LampMasterSchedule.Skip? = nil, failure: LampMasterRun.Failure? = nil,
        model: String? = nil, seconds: Double? = nil, tokens: Int = 0, costUSD: Double? = nil,
        sessions: Int = 0, frameTokens: Int? = nil, proposed: Int = 0,
        rejected: [String: Int] = [:], shown: Int = 0, digest: String? = nil
    ) {
        self.at = at
        self.trigger = trigger
        self.outcome = outcome
        self.skip = skip
        self.failure = failure
        self.model = model
        self.seconds = seconds
        self.tokens = tokens
        self.costUSD = costUSD
        self.sessions = sessions
        self.frameTokens = frameTokens
        self.proposed = proposed
        self.rejected = rejected
        self.shown = shown
        self.digest = digest
    }
}

/// A suggestion that reached the panel, and what became of it.
public struct LampMasterShown: Codable, Sendable, Equatable, Identifiable {

    public enum Outcome: String, Codable, Sendable, Equatable, CaseIterable {
        /// Its action was clicked.
        case accepted
        /// Dismissed with *Ignore*.
        case ignored
        /// *Don't suggest this kind again*.
        case muted
        /// Marked wrong: counted apart from ignored, because a wrong suggestion
        /// is a defect and an unwanted one is only a preference.
        case wrong
        /// Nobody reacted for four hours.
        case expired
        /// The sessions it was about left the frame: it settled by itself.
        case superseded
    }

    public let id: String
    public let at: Date
    public let suggestion: LampMasterAdvice.Suggestion
    public let outcome: Outcome?
    public let settledAt: Date?

    public init(
        id: String, at: Date, suggestion: LampMasterAdvice.Suggestion,
        outcome: Outcome? = nil, settledAt: Date? = nil
    ) {
        self.id = id
        self.at = at
        self.suggestion = suggestion
        self.outcome = outcome
        self.settledAt = settledAt
    }

    public var isOpen: Bool { outcome == nil }

    public func settled(_ outcome: Outcome, at date: Date) -> LampMasterShown {
        LampMasterShown(id: id, at: at, suggestion: suggestion, outcome: outcome, settledAt: date)
    }
}

/// What the files of past rounds say: when the last round ran, what today
/// cost, which suggestions are still open, and what the next frame is told
/// about the last ones.
public enum LampMasterLedger {

    public static let expiresAfter: TimeInterval = 4 * 60 * 60
    /// Two weeks: the window the plan reads acceptance over before switching
    /// a kind off.
    public static let keptFor: TimeInterval = 14 * 24 * 60 * 60
    /// How far back the frame's `recent` reaches: the validator's own window.
    public static let recentWindow: TimeInterval = LampMasterValidator.repeatWindow

    /// The last round that reached `claude`, failed or not.
    public static func lastRun(_ rounds: [LampMasterRound]) -> LampMasterRound? {
        rounds.filter { $0.outcome != .skipped }.max { $0.at < $1.at }
    }

    /// Tokens spent on the calendar day `now` falls on.
    public static func tokens(on now: Date, in rounds: [LampMasterRound], calendar: Calendar = .current) -> Int {
        rounds.filter { calendar.isDate($0.at, inSameDayAs: now) }.reduce(0) { $0 + $1.tokens }
    }

    /// The shown entries for one round's verdict, with ids stable within it.
    public static func entries(for shown: [LampMasterAdvice.Suggestion], at date: Date) -> [LampMasterShown] {
        let stamp = Int(date.timeIntervalSince1970)
        return shown.enumerated().map { LampMasterShown(id: "\(stamp)-\($0.offset)", at: date, suggestion: $0.element) }
    }

    /// Settles what settled by itself: open entries older than four hours
    /// expire, and those whose sessions all left the frame are superseded.
    /// Old entries beyond the two weeks are dropped.
    ///
    /// - Parameter present: the short ids of the sessions in the current frame.
    public static func settle(_ shown: [LampMasterShown], present: Set<String>, now: Date) -> [LampMasterShown] {
        shown
            .filter { now.timeIntervalSince($0.at) <= keptFor }
            .map { entry in
                guard entry.isOpen else { return entry }
                if now.timeIntervalSince(entry.at) >= expiresAfter { return entry.settled(.expired, at: now) }
                let named = Set(entry.suggestion.sessions.map { String($0.prefix(8)) })
                if named.isDisjoint(with: present) { return entry.settled(.superseded, at: now) }
                return entry
            }
    }

    /// The user's reaction to one entry. An entry already settled keeps its
    /// first outcome: a late click on an expired card is not an acceptance.
    public static func resolve(
        _ shown: [LampMasterShown], id: String, outcome: LampMasterShown.Outcome, now: Date
    ) -> [LampMasterShown] {
        shown.map { $0.id == id && $0.isOpen ? $0.settled(outcome, at: now) : $0 }
    }

    /// The open entries, newest first: what the panel shows.
    public static func open(_ shown: [LampMasterShown]) -> [LampMasterShown] {
        shown.filter(\.isOpen).sorted(by: newestFirst)
    }

    /// When each key was last shown, for the validator.
    public static func shownAt(_ shown: [LampMasterShown]) -> [String: Date] {
        shown.reduce(into: [:]) { result, entry in
            let key = entry.suggestion.key
            if result[key].map({ $0 < entry.at }) ?? true { result[key] = entry.at }
        }
    }

    /// The last day's suggestions as the frame tells them to the next round.
    public static func recent(_ shown: [LampMasterShown], now: Date) -> [LampMasterFrame.Recent] {
        shown
            .filter { now.timeIntervalSince($0.at) <= recentWindow }
            .sorted(by: newestFirst)
            .map {
                LampMasterFrame.Recent(
                    key: $0.suggestion.key, kind: $0.suggestion.kind.rawValue,
                    outcome: $0.outcome?.rawValue ?? "open",
                    minutesAgo: max(0, Int(now.timeIntervalSince($0.at) / 60))
                )
            }
    }

    /// Newest first, and in the order a round gave them when they share its time.
    static func newestFirst(_ a: LampMasterShown, _ b: LampMasterShown) -> Bool {
        a.at != b.at ? a.at > b.at : a.id < b.id
    }

    /// Rejections counted by reason.
    public static func rejections(_ verdict: LampMasterValidator.Verdict) -> [String: Int] {
        verdict.rejected.reduce(into: [:]) { $0[$1.1.rawValue, default: 0] += 1 }
    }

    // MARK: - The files

    /// One record a line, dates in ISO 8601 so the file reads by eye.
    public static func line<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The records of a file. A line that does not read is skipped, not fatal:
    /// a write cut short by a crash must cost that line, never the history.
    public static func records<T: Decodable>(_ text: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }
}
