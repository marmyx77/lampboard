import Foundation

/// What the companion mod tells the panel about the session it runs in.
///
/// The mod (`lampboard@lampboard`, in `mod/`) runs inside every Claude Code
/// session from 2.1.287 and posts these to `POST /mod`. It carries only what
/// the hooks cannot know: the context as the session itself counts it, what
/// the session has cost, the account's rate-limit windows, where it draws, and
/// why it ended. The colours stay with the hooks (D65): they are proven on
/// every version and every surface, and a second source for the same `Stop`
/// would only add a race between two messages saying one thing.
///
/// Everything here is checked on the way in. The mod is ours, but the route
/// takes whatever a process of this user sends it, so a report is bounded in
/// every dimension before anything is kept: ids of a known shape, numbers in
/// range, words from a short list.
public enum ModReport: Equatable, Sendable {

    case start(session: String, start: Start)
    case measure(session: String, measure: Measure)
    case end(session: String, reason: EndReason)

    public var session: String {
        switch self {
        case .start(let session, _), .measure(let session, _), .end(let session, _): return session
        }
    }

    /// `session.start`: where the session draws and whether a person is there.
    public struct Start: Equatable, Sendable {
        /// `terminal`, `desktop`, … as Claude Code names it; `nil` for a `-p` run.
        public let surface: String?
        public let interactive: Bool
        public let model: String?

        public init(surface: String?, interactive: Bool, model: String?) {
            self.surface = surface
            self.interactive = interactive
            self.model = model
        }
    }

    /// `session.measure`: the status line's figures.
    public struct Measure: Equatable, Sendable {
        /// Absent on the first measurement, which arrives before the first
        /// response and knows only the window. Measured on 4 October 2026.
        public let tokens: Int?
        public let window: Int?
        public let model: String?
        public let rateLimits: [RateLimit]
        public let costUSD: Double?

        public init(tokens: Int?, window: Int?, model: String?, rateLimits: [RateLimit], costUSD: Double?) {
            self.tokens = tokens
            self.window = window
            self.model = model
            self.rateLimits = rateLimits
            self.costUSD = costUSD
        }
    }

    /// One rate-limit window as the session last saw it.
    public struct RateLimit: Equatable, Sendable {
        /// `five_hour`, `seven_day`, … kept as the word Claude Code uses: the
        /// list is read, not fixed, as in `AccountLimits`.
        public let kind: String
        public let percent: Int
        public let resetsAt: Date?

        public init(kind: String, percent: Int, resetsAt: Date?) {
            self.kind = kind
            self.percent = min(max(percent, 0), 100)
            self.resetsAt = resetsAt
        }
    }

    /// Claude Code's own `SessionEnd` reasons; anything else reads as `other`.
    public enum EndReason: String, Equatable, Sendable, CaseIterable {
        case exit = "prompt_input_exit"
        case clear, resume, logout, other
    }

    // MARK: - Decoding

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable
        case unknownKind
        case badSession
        case badVersion

        public var description: String {
            switch self {
            case .unreadable: return "not a mod report"
            case .unknownKind: return "unknown kind"
            case .badSession: return "session id of an unexpected shape"
            case .badVersion: return "unsupported report version"
            }
        }
    }

    /// The version of the wire format the mod writes. A report of another one is
    /// refused rather than half-read: a mod newer than the panel must say so.
    public static let version = 1

    /// Bounds. Generous for a real session, tight for anything else.
    static let maxTokens = 100_000_000
    static let maxCostUSD = 1_000_000.0
    static let maxRateLimits = 8
    static let maxWordLength = 40
    static let maxModelLength = 80

    public static func decode(_ data: Data) throws -> ModReport {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw Failure.unreadable }
        guard wire.v == version else { throw Failure.badVersion }
        guard let session = wire.session, isSessionId(session) else { throw Failure.badSession }
        switch wire.kind {
        case "start":
            return .start(session: session, start: Start(
                surface: wire.surface.flatMap(word), interactive: wire.interactive ?? false,
                model: wire.model.flatMap(model)
            ))
        case "measure":
            let limits = (wire.rateLimits ?? []).prefix(maxRateLimits).compactMap { limit -> RateLimit? in
                guard let kind = limit.kind.flatMap(word), let percent = limit.percentUsed,
                      percent.isFinite else { return nil }
                return RateLimit(kind: kind, percent: Int(percent.rounded()),
                                 resetsAt: limit.resetsAt.flatMap(Self.date))
            }
            return .measure(session: session, measure: Measure(
                tokens: wire.context?.tokens.flatMap { (0...maxTokens).contains($0) ? $0 : nil },
                window: wire.context?.window.flatMap { (1...maxTokens).contains($0) ? $0 : nil },
                model: wire.model.flatMap(model),
                rateLimits: Array(limits),
                costUSD: wire.cost?.usd.flatMap { $0.isFinite && (0...maxCostUSD).contains($0) ? $0 : nil }
            ))
        case "end":
            return .end(session: session, reason: wire.reason.flatMap(EndReason.init(rawValue:)) ?? .other)
        default:
            throw Failure.unknownKind
        }
    }

    /// A Claude Code session id: a UUID, so letters, digits and dashes.
    public static func isSessionId(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A short lowercase word (`terminal`, `five_hour`), or nothing.
    static func word(_ raw: String) -> String? {
        guard (1...maxWordLength).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return raw
    }

    /// A model id (`claude-opus-5-5`, `claude-sonnet-5-5[1m]`), or nothing.
    static func model(_ raw: String) -> String? {
        guard (1...maxModelLength).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline && $0 != "\"" })
        else { return nil }
        return raw
    }

    static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private struct Wire: Decodable {
        let v: Int?
        let kind: String?
        let session: String?
        let surface: String?
        let interactive: Bool?
        let model: String?
        let context: Context?
        let rateLimits: [Limit]?
        let cost: Cost?
        let reason: String?

        struct Context: Decodable { let tokens: Int?; let window: Int? }
        struct Limit: Decodable { let kind: String?; let percentUsed: Double?; let resetsAt: String? }
        struct Cost: Decodable { let usd: Double? }
    }
}

extension ModReport.Measure {

    /// The context as a row reads it, or `nil` before the first response.
    ///
    /// `reported`: the session counted it, so no window table of ours and no
    /// transcript arithmetic stand between the figure and the truth. The model
    /// is the one the mod named, else the one the row already had: the ring's
    /// letter should not blank because a measurement left it out.
    public func reading(previous: ContextReading?, at now: Date) -> ContextReading? {
        guard let tokens else { return nil }
        return ContextReading(
            tokens: tokens, model: model ?? previous?.model ?? "",
            window: window ?? previous?.window, confidence: .reported, at: now
        )
    }
}
