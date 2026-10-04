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
    /// `tool.call`: a tool began or finished running (5.7).
    case tool(session: String, run: ToolRun)

    public var session: String {
        switch self {
        case .start(let session, _), .measure(let session, _), .end(let session, _), .tool(let session, _): return session
        }
    }

    /// One tool call, at its start or its end. The detail is the shell line for
    /// Bash, or which file: the same allow-list as `PendingAsk`, never contents.
    public struct ToolRun: Equatable, Sendable {
        public let id: String
        public let tool: String
        public let detail: String?
        public let finished: Bool

        public init(id: String, tool: String, detail: String?, finished: Bool) {
            self.id = id
            self.tool = tool
            self.detail = detail
            self.finished = finished
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
        /// The session runs on Claude Code's default configuration, so its
        /// windows are those of the account this Mac's allowance strip reads.
        /// A session with a `CLAUDE_CONFIG_DIR` of its own may be another
        /// account, and a report that does not say is taken as one (mod 1.0.0).
        public let defaultAccount: Bool

        public init(
            tokens: Int?, window: Int?, model: String?, rateLimits: [RateLimit], costUSD: Double?,
            defaultAccount: Bool = false
        ) {
            self.tokens = tokens
            self.window = window
            self.model = model
            self.rateLimits = rateLimits
            self.costUSD = costUSD
            self.defaultAccount = defaultAccount
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
                // Clamped as a Double first: `Int(1e300)` is not a large number,
                // it is a crash of the whole panel.
                return RateLimit(kind: kind, percent: Int(min(max(percent, 0), 100).rounded()),
                                 resetsAt: limit.resetsAt.flatMap(Self.date))
            }
            return .measure(session: session, measure: Measure(
                tokens: wire.context?.tokens.flatMap { count($0, from: 0) },
                window: wire.context?.window.flatMap { count($0, from: 1) },
                model: wire.model.flatMap(model),
                rateLimits: Array(limits),
                costUSD: wire.cost?.usd.flatMap { $0.isFinite && (0...maxCostUSD).contains($0) ? $0 : nil },
                defaultAccount: wire.config == "default"
            ))
        case "end":
            return .end(session: session, reason: wire.reason.flatMap(EndReason.init(rawValue:)) ?? .other)
        case "tool":
            guard let id = wire.id, isSessionId(id) || isCallId(id),
                  let tool = wire.tool.flatMap(toolName),
                  wire.phase == "start" || wire.phase == "end"
            else { throw Failure.unreadable }
            return .tool(session: session, run: ToolRun(
                id: id, tool: tool, detail: wire.detail.flatMap(detail), finished: wire.phase == "end"
            ))
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
    /// An allowlist, not a blocklist: an escape or a control character in a
    /// model name would reach the row, the tooltips and LampMaster's frame.
    static func model(_ raw: String) -> String? {
        guard (1...maxModelLength).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-[]/".contains($0)) })
        else { return nil }
        return raw
    }

    /// A token count: read as a number of any spelling (`47162`, `4.7162e4`),
    /// kept only when it is a whole count in range. Decoding it as `Int` would
    /// have lost the whole report to a float.
    static func count(_ raw: Double, from lower: Int) -> Int? {
        guard raw.isFinite, raw >= Double(lower), raw <= Double(maxTokens) else { return nil }
        return Int(raw.rounded())
    }

    /// `toolu_01AbC…`: letters, digits, `_` and `-`.
    static func isCallId(_ id: String) -> Bool {
        (1...80).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `Bash`, `mcp__docs__search`: a tool's name, or nothing.
    static func toolName(_ raw: String) -> String? {
        guard (1...maxModelLength).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) })
        else { return nil }
        return raw
    }

    /// One line, printable, secrets masked, at most `PendingAsk.detailLimit`,
    /// cut where it says so.
    ///
    /// Not only the control characters: bidi overrides, zero-width marks and
    /// line separators (format and separator categories) can reorder or hide part
    /// of a command on a card, which is the one place it is read to judge it.
    static func detail(_ raw: String) -> String? {
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return " "
            default: return scalar
            }
        }))
        let line = masked(visible).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count <= PendingAsk.detailLimit ? line : String(line.prefix(PendingAsk.detailLimit - 1)) + "…"
    }

    /// A shell line with what looks like a secret replaced by `***`: a variable
    /// named like a key or a password, a password in a URL, an Authorization
    /// header, a `--password` argument. Commands carry them, and this one is
    /// shown on a card that may be on a shared screen.
    static func masked(_ line: String) -> String {
        let rules: [(String, String)] = [
            (#"(?i)\b(\w*(?:KEY|TOKEN|SECRET|PASS(?:WORD)?|AUTH)\w*)=(\S+)"#, "$1=***"),
            (#"://([^/\s:@]+):[^@\s/]+@"#, "://$1:***@"),
            (#"(?i)(authorization:\s*)(\S+(?:\s+\S+)?)"#, "$1***"),
            (#"(?i)(--password[=\s]+)(\S+)"#, "$1***"),
        ]
        return rules.reduce(line) { text, rule in
            text.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
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
        let config: String?
        let id: String?
        let tool: String?
        let detail: String?
        let phase: String?

        struct Context: Decodable { let tokens: Double?; let window: Double? }
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
