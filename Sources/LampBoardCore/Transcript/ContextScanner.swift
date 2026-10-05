import Foundation

/// Finds the last honest token count in a transcript, and says what happened after it.
///
/// Reads backwards from the end, because the answer is almost always in the last
/// few records and a transcript can be a hundred megabytes. Everything below is
/// a rule that a naive version gets wrong, and each one was measured on real
/// files rather than imagined:
///
/// - **A `<synthetic>` record is not a reply.** Claude Code writes one when it
///   refuses — including, memorably, *"Prompt is too long"* — with a usage block
///   of zeros. Taking the last usage-bearing record would print **0%** at the
///   exact moment a session was full. Filtered on the model string, not on the
///   error flag: that flag is false on many of them.
/// - **Zero at the top level does not mean zero.** A few records report nothing
///   in `usage` while `usage.iterations` holds the real figure. The top level
///   stays primary — most records have no iterations at all — and the last
///   iteration is the fallback.
/// - **The model comes from the same record as the tokens.** A session switches
///   models mid-flight, and one real transcript does it twenty-eight times.
/// - **The order in the file is not chronological.** A resumed session replays
///   history; thousands of records step backwards in time, one by nine days. So
///   this reads by position from the end, and never sorts by timestamp or takes
///   a maximum.
public enum ContextScanner {

    /// The reading, or `nil` when the tail holds no usable record.
    ///
    /// - Parameter tail: the end of the transcript. A partial first line is
    ///   expected and skipped by the JSON decode, which is why the caller may
    ///   read from an arbitrary offset.
    public static func read(tail: String) -> ContextReading? {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)

        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            guard let record = object(from: lines[index]),
                  let message = record["message"] as? [String: Any],
                  let model = (message["model"] as? String)?.trimmed.nilIfEmpty,
                  model != "<synthetic>",
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let tokens = contextTokens(in: usage)
            guard tokens > 0 else { continue }

            return ContextReading(
                tokens: tokens,
                model: model,
                window: ContextWindows.window(for: model),
                confidence: confidence(after: index, in: lines),
                at: timestamp(record["timestamp"]),
                cacheLifetime: cacheLifetime(through: index, in: lines)
            )
        }
        return nil
    }

    /// How long the prompt cache lives, from the last reply at or before
    /// `index` that wrote it: its usage says `ephemeral_1h` or `ephemeral_5m`.
    /// A reply that only read it keeps that lifetime, refreshed. `nil` when no
    /// write is in sight: not known, so not shown.
    static func cacheLifetime(through index: Int, in lines: [Substring]) -> TimeInterval? {
        for position in stride(from: index, through: 0, by: -1) {
            guard let record = object(from: lines[position]),
                  let usage = (record["message"] as? [String: Any])?["usage"] as? [String: Any],
                  let creation = usage["cache_creation"] as? [String: Any]
            else { continue }
            if ((creation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0) > 0 { return 3_600 }
            if ((creation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0) > 0 { return 300 }
        }
        return nil
    }

    /// Everything the model was given: the fresh tokens, what was written into
    /// the cache, and what was read back out of it.
    ///
    /// This is the same sum Claude Code's own status line reports as
    /// `total_input_tokens` — verified against a live payload rather than
    /// derived, because a plausible-looking sum that is wrong by a cache would
    /// be undetectable from the outside.
    static func contextTokens(in usage: [String: Any]) -> Int {
        let direct = total(of: usage)
        if direct > 0 { return direct }
        guard let iterations = usage["iterations"] as? [[String: Any]],
              let last = iterations.last
        else { return 0 }
        return total(of: last)
    }

    private static func total(of block: [String: Any]) -> Int {
        ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0) { $0 + ((block[$1] as? NSNumber)?.intValue ?? 0) }
    }

    /// What the records after the reading do to it.
    ///
    /// A compaction rewrites the context entirely, so the number before it
    /// describes a session that no longer exists. Anything the user or a tool
    /// added is context the reading cannot see, so the reading becomes a floor.
    static func confidence(after index: Int, in lines: [Substring]) -> ContextReading.Confidence {
        var sawAddition = false

        for line in lines[(index + 1)...] {
            guard let record = object(from: line) else { continue }
            let kind = (record["type"] as? String) ?? ""

            if kind == "compact_boundary" || record["compactMetadata"] != nil {
                return .unknown
            }
            if let message = record["message"] as? [String: Any],
               (message["model"] as? String) == "<synthetic>" {
                // A refusal after the reading: whatever the context is now, it is
                // not what the reading says.
                return .unknown
            }
            if ["user", "attachment", "queue-operation"].contains(kind) {
                sawAddition = true
            }
        }
        return sawAddition ? .floor : .exact
    }

    private static func object(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parsed
    }

    /// Claude Code writes milliseconds (`…08:07.456Z`), which the plain ISO 8601
    /// reader refuses: found by R3b's test, every reading's time was `nil`.
    private static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
