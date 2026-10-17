import Foundation

/// When a conversation last actually said something.
///
/// **The file's modification date is not that**, and the comment that used to
/// claim otherwise, "the transcript is the only file that moves when a session
/// does something", is the premise this exists to replace. Measured: a project
/// whose last exchange was on 26 August showed as active 49 minutes ago, because
/// two records had been appended to its transcript that morning:
///
/// ```text
/// {"type":"last-prompt", …}      no timestamp
/// {"type":"bridge-session", …}   no timestamp
/// ```
///
/// Bookkeeping, written by tooling around the session rather than by the session,
/// and enough to move the mtime. A row that says a week-old project was touched
/// an hour ago is worse than a row saying nothing: it is the panel inventing
/// activity, which is the one thing every rule here is written to prevent.
///
/// So the answer comes from the last record that **carries a timestamp**. A
/// record with no timestamp is not a moment, whatever it did to the file.
public enum TranscriptActivity {

    /// How much of the end of the file to read.
    ///
    /// A transcript can be tens of megabytes and the answer is in its last lines.
    /// Sixty-four kilobytes covers a long run of tool calls; past that the mtime
    /// is a defensible fallback, because a file being written that heavily is a
    /// file something is genuinely doing.
    public static let tailLimit = 64 * 1024

    /// The moment of the last timestamped record in a chunk read from the end of
    /// a transcript.
    ///
    /// - Parameter isWholeFile: `false` means the chunk starts mid-line, so the
    ///   first line is a fragment and is dropped. Parsing it would at best fail
    ///   and at worst find a timestamp inside a truncated string.
    public static func lastTimestamp(inTailChunk chunk: String, isWholeFile: Bool = false) -> Date? {
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = record["timestamp"] as? String,
                  let moment = date(from: text)
            else { continue }
            return moment
        }
        return nil
    }

    /// Whether the tail ends inside a turn: `true` after a prompt, a tool call or
    /// a tool's result, `false` after the model ended its turn, `nil` when the
    /// tail holds no turn at all (a session just resumed, bookkeeping only).
    ///
    /// Claude Code's own file says `busy` for as long as anything runs for the
    /// session, its background agents included. Measured on the always-on
    /// machine: a session whose turn had ended, its agents still at work, read
    /// `busy` six hours on; the Mac, hearing its hooks, drew it blue, and the
    /// phone, reading the file, yellow. A turn that ended is not one at work.
    /// Records queued after it, attachments and bookkeeping say nothing either way.
    public static func turnIsOpen(inTailChunk chunk: String, isWholeFile: Bool = false) -> Bool? {
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch record["type"] as? String {
            // The summary a compaction writes is a `user` record nobody typed
            // (D177). Taken for a prompt, it opened a turn on a conversation
            // Claude Code had compacted while idle; the records before it say
            // whether a turn was running when the compaction began.
            case "user" where record["isCompactSummary"] as? Bool == true:
                continue
            case "user":
                return true
            case "assistant":
                let reason = (record["message"] as? [String: Any])?["stop_reason"] as? String
                return reason == nil || reason == "tool_use" || reason == "pause_turn"
            case "system":
                if let subtype = record["subtype"] as? String, ["turn_duration", "stop_hook_summary"].contains(subtype) {
                    return false
                }
            default:
                continue
            }
        }
        return nil
    }

    /// ISO 8601, with and without fractional seconds: transcripts carry both.
    private static func date(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
