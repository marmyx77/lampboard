import Foundation

/// How the round runs `claude`, and how its answer is read back.
///
/// WHY EVERY FLAG
/// Run plainly, the same call cost 268,908 tokens on 4 October 2026: the
/// user's MCP connectors, skills and rules all came along for a question that
/// needed none of them. With these flags the base was 689. `disableAllHooks`
/// and `--no-session-persistence` also keep the round from turning up as a
/// session in this very panel, and in anything else that listens to hooks.
///
/// WHY STANDARD INPUT
/// The frame carries pieces of the user's conversations. An argument can be
/// read by any process on the Mac with `ps`; standard input cannot. So the
/// arguments hold only what is the same for every user, and the frame goes in
/// through the pipe.
public enum LampMasterCommand {

    /// The models the round may use, as `claude --model` names them.
    public static let models = ["opus", "sonnet"]
    /// Opus, because on the same frame it found the links between sessions
    /// and Sonnet did not (4 October: 16.9 s and $0.079 against 9.2 s and $0.035).
    public static let defaultModel = "opus"
    /// Two minutes against a measured 16.9 s: room, not a target.
    public static let timeout: TimeInterval = 120
    /// With no tools the round still takes two turns: the structured answer is
    /// one (measured on 4 October 2026, `num_turns: 2`). The ceiling is there
    /// for the day a tool is added, and it bounds the cost either way.
    public static let maxTurns = 6

    public static func arguments(model: String, system: String, schema: String = LampMasterPrompt.schema) -> [String] {
        [
            "-p", "--model", model, "--output-format", "json", "--json-schema", schema,
            "--tools", "", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--disable-slash-commands", "--setting-sources", "",
            "--max-turns", String(maxTurns), "--system-prompt", system,
        ]
    }
}

/// What one run reported, read from `claude -p --output-format json`.
///
/// The tokens are read whatever happened: a run that failed still spent them,
/// and the daily ceiling has to count what was spent, not what was useful.
public struct LampMasterRun: Sendable, Equatable {

    public enum Failure: String, Sendable, Equatable, Codable {
        /// Standard output was not the JSON envelope.
        case unreadable
        /// The envelope says the run failed.
        case reportedError
        /// The envelope came, without an answer in the schema.
        case offSchema
        /// Still running at the deadline, and stopped.
        case timedOut
        /// `claude` could not be started at all.
        case notLaunched
    }

    public let advice: LampMasterAdvice?
    public let failure: Failure?
    /// Input as billed: fresh, read from the cache and written to it.
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double?
    public let seconds: Double?

    public var tokens: Int { inputTokens + outputTokens }

    public init(
        advice: LampMasterAdvice?, failure: Failure?, inputTokens: Int = 0, outputTokens: Int = 0,
        costUSD: Double? = nil, seconds: Double? = nil
    ) {
        self.advice = advice
        self.failure = failure
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.seconds = seconds
    }

    public static func failed(_ failure: Failure, seconds: Double? = nil) -> LampMasterRun {
        LampMasterRun(advice: nil, failure: failure, seconds: seconds)
    }

    public static func read(_ output: Data) -> LampMasterRun {
        guard let envelope = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            return .failed(.unreadable)
        }
        let usage = envelope["usage"] as? [String: Any] ?? [:]
        let count: (String) -> Int = { (usage[$0] as? NSNumber)?.intValue ?? 0 }
        let input = count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens")
        let seconds = (envelope["duration_ms"] as? NSNumber).map { $0.doubleValue / 1_000 }
        let cost = (envelope["total_cost_usd"] as? NSNumber)?.doubleValue

        let reportedError = (envelope["is_error"] as? Bool) == true
            || (envelope["subtype"] as? String).map { $0 != "success" } == true
        let advice = reportedError ? nil : LampMasterAdvice.decode(output)
        let failure: Failure? = reportedError ? .reportedError : (advice == nil ? .offSchema : nil)
        return LampMasterRun(
            advice: advice, failure: failure, inputTokens: input, outputTokens: count("output_tokens"),
            costUSD: cost, seconds: seconds
        )
    }
}
