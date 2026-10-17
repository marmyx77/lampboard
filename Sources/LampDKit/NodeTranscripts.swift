import Foundation
import LampBoardCore

/// The last messages of a conversation on this machine, for `transcript`.
///
/// Read with the Core's transcript reader (`TranscriptTail`), the one the Mac's
/// live view reads with: what counts as a message a person wrote or an answer,
/// and what is only activity, is decided there. Only the person's messages and
/// the answers are sent, with how many earlier ones were left out.
public enum NodeTranscripts {

    /// How much of a transcript is read, from its end. Past it the earlier
    /// messages are not counted: a conversation of that size has a `notSent`
    /// that is already large, and reading hundreds of megabytes to make it
    /// exact would hold a phone's request for seconds.
    public static let window: UInt64 = 64 * 1024 * 1024
    static let piece = 1024 * 1024

    /// Where the transcript of `session` begun in `cwd` is: where Claude Code
    /// derives it, or wherever a session in a git worktree filed it under its
    /// id, as the probe looks for it.
    public static func locate(session: String, cwd: String?, claudeDirectory: String) -> String? {
        let manager = FileManager.default
        if let cwd {
            let derived = claudeDirectory + "/projects/" + TranscriptLocator.directoryName(forWorkspace: cwd) + "/" + session + ".jsonl"
            if manager.fileExists(atPath: derived) { return derived }
        }
        let projects = claudeDirectory + "/projects"
        for folder in (try? manager.contentsOfDirectory(atPath: projects)) ?? [] {
            let candidate = projects + "/" + folder + "/" + session + ".jsonl"
            if manager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The last `limit` messages of the transcript at `path`, or `nil` when it
    /// cannot be read.
    public static func read(session: String, path: String, limit: Int) -> V1Transcript? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        var tail = TranscriptTail()
        var kept: [V1Transcript.Message] = []
        var total = 0
        // Bytes up to the last whole line are decoded; the rest waits for the
        // next piece, so a character cut in two by a piece is never mangled.
        var pending = Data()
        var skipFirstLine = start > 0
        func take(_ text: String) {
            for entry in tail.consume(text) where entry.isConversation {
                total += 1
                kept.append(V1Transcript.Message(role: entry.kind == .human ? "user" : "assistant", text: entry.text,
                                                 at: entry.timestamp))
                if kept.count > limit { kept.removeFirst(kept.count - limit) }
            }
        }
        while let data = try? handle.read(upToCount: piece), !data.isEmpty {
            pending.append(data)
            if skipFirstLine {
                // A window that starts mid-line: its first line is a piece of one.
                guard let newline = pending.firstIndex(of: 0x0A) else { continue }
                pending = Data(pending[pending.index(after: newline)...])
                skipFirstLine = false
            }
            guard let last = pending.lastIndex(of: 0x0A) else { continue }
            take(String(decoding: pending[...last], as: UTF8.self))
            pending = Data(pending[pending.index(after: last)...])
        }
        // The last line, when the file does not end with a newline.
        if !skipFirstLine { take(String(decoding: pending, as: UTF8.self) + "\n") }
        return V1Transcript(session: session, messages: kept, notSent: total - kept.count)
    }
}
