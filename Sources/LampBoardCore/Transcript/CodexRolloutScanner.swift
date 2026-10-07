import Foundation

/// Reads how full a Codex session's context window is, from its rollout file.
///
/// Codex is in a better position than Claude Code and the difference is worth
/// stating rather than smoothing over. Claude Code records what a turn consumed
/// and says nothing anywhere about the size of the window, so our denominator is
/// a table we built and validated against 236 real compactions — a number that a
/// vendor can invalidate without telling anybody. Codex writes both halves into
/// the same record:
///
/// ```json
/// {"type":"token_count",
///  "info":{"last_token_usage":{"input_tokens":16146, …},
///          "model_context_window":258400},
///  "rate_limits":{"primary":{"used_percent":0.0,"window_minutes":10080}}}
/// ```
///
/// So a Codex reading is `.declared`: nothing about it rests on us.
///
/// Two choices worth naming, both borrowed from the Claude side because both
/// were paid for there.
///
/// **`last_token_usage`, not `total_token_usage`.** The panel answers one
/// question — *what can this session still do* — and the cumulative figure
/// answers a different one. The rollout measured while writing this held
/// 32,187 cumulative against 16,146 in the window: a ring drawn from the wrong
/// one reads twice as full as the session is.
///
/// **Backwards by position, never sorted by timestamp.** A resumed session
/// replays its history, so the last record in the file is the current one even
/// when an earlier line carries a later clock. This is the same reasoning as
/// `ContextScanner`, and it was a real transcript stepping back nine days that
/// established it.
public enum CodexRolloutScanner {

    /// The reading, from the tail of a rollout. `nil` when the tail holds no
    /// token count — a session that has not had a turn yet, or a tail cut above
    /// the last one.
    public static func read(tail: String) -> ContextReading? {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)

        // The model is not in the token record. It sits in `turn_context`, which
        // is written once per turn, so the nearest one *above* the count is the
        // model that produced it — the same rule as reading the model off the
        // record the tokens came from, applied to a format that splits them.
        var model = ""
        var reading: ContextReading?

        for index in lines.indices.reversed() {
            guard let record = object(from: lines[index]),
                  let payload = record["payload"] as? [String: Any]
            else { continue }

            let kind = payload["type"] as? String

            if reading == nil, kind == "token_count" {
                guard let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let tokens = integer(last["input_tokens"])
                else { continue }

                reading = ContextReading(
                    tokens: tokens,
                    model: "",
                    window: integer(info["model_context_window"]),
                    confidence: .declared,
                    at: timestamp(record["timestamp"])
                )
                continue
            }

            // Keep walking up for the model that belongs to that count. Stop as
            // soon as both are in hand: a rollout has thousands of lines and
            // there is nothing above to learn.
            if reading != nil, kind == nil || kind == "turn_context" {
                if let name = (payload["model"] as? String)?.trimmed, !name.isEmpty {
                    model = name
                    break
                }
            }
        }

        guard let reading else { return nil }
        return ContextReading(
            tokens: reading.tokens,
            model: model,
            window: reading.window,
            confidence: reading.confidence,
            at: reading.at
        )
    }

    /// How much of the plan's allowance the account has spent, from the same
    /// record as the token count.
    ///
    /// Deliberately **not** on the ring. The ring has one meaning — how full this
    /// conversation is — and a second quantity sharing it would make two rows say
    /// different things with the same shape. This belongs in the card, where a
    /// figure that exists for one harness and not the other costs nothing.
    ///
    /// It is also a fact about the *account*, not the session: every Codex row
    /// shows the same number, and a reader who did not know that would read it
    /// as a property of the row.
    public static func planUsage(tail: String) -> PlanUsage? {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        for index in lines.indices.reversed() {
            guard let record = object(from: lines[index]),
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let percent = double(primary["used_percent"])
            else { continue }

            return PlanUsage(
                usedPercent: percent,
                windowMinutes: integer(primary["window_minutes"]),
                plan: (limits["plan_type"] as? String)?.trimmed.nilIfEmpty
            )
        }
        return nil
    }

    private static func object(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Codex writes these as numbers; a string would still be a number to a
    /// reader, and refusing it would drop a valid reading over a type.
    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private static func double(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return ISO8601DateFormatter.withFractionalSeconds.date(from: text)
            ?? ISO8601DateFormatter.plain.date(from: text)
    }
}

/// What the plan allows and how much of it is gone.
public struct PlanUsage: Sendable, Equatable {
    public let usedPercent: Double
    /// The length of the allowance window. Codex's is 10,080 minutes: seven days.
    public let windowMinutes: Int?
    /// The plan's own name for itself, when it gives one.
    public let plan: String?

    public init(usedPercent: Double, windowMinutes: Int?, plan: String?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.plan = plan
    }

    /// The sentence for the card. Says the window in days, because "10080
    /// minutes" is a number nobody converts while looking at a panel.
    public var sentence: String {
        let rounded = usedPercent < 1 && usedPercent > 0
            ? String(format: "%.1f", usedPercent)
            : String(Int(usedPercent.rounded()))
        guard let windowMinutes, windowMinutes > 0 else { return "\(rounded)% of the plan used" }
        let days = Double(windowMinutes) / 1440.0
        let period = days >= 1
            ? "\(Int(days.rounded()))-day"
            : "\(Int((Double(windowMinutes) / 60.0).rounded()))-hour"
        return "\(rounded)% of the \(period) plan used"
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
