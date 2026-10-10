import Foundation

/// The live view's chat (D147): where a session's transcript is, and its lines
/// as they arrive, whole. The decoding and the drawing are Clarc's.
public enum LiveChatSource {

    /// Lines kept: a long session's transcript runs to megabytes, and a chat
    /// shows its end.
    public static let keptLines = 800

    /// The transcript of a session on another machine, relative to the home
    /// directory ssh starts in.
    public static func remotePath(sessionId: String, cwd: String) -> String {
        ".claude/projects/\(TranscriptLocator.directoryName(forWorkspace: cwd))/\(sessionId).jsonl"
    }

    /// What follows it over there: its last lines, then each new one, for as
    /// long as LampBoard holds the connection's input open. When it closes (the
    /// window, LampBoard quitting), `cat` ends and takes `tail` with it, which
    /// otherwise would wait for its next line to learn nobody reads it.
    public static func remoteFollow(path: String) -> String {
        NewSession.posix("tail -n \(keptLines) -F \(NewSession.shellQuoted(path)) & p=$!; cat >/dev/null; kill $p")
    }
}

/// Bytes in, whole lines out: a line is kept only once its newline has arrived,
/// the oldest dropped past `keep`.
public struct TranscriptLineBuffer: Equatable, Sendable {
    public private(set) var lines: [String] = []
    private var partial = Data()
    private let keep: Int

    public init(keep: Int = LiveChatSource.keptLines) { self.keep = keep }

    /// Appends what arrived; `true` when a line was completed. One pass over
    /// the bytes, the rest kept once: a four-megabyte read is not re-copied
    /// for every line in it.
    @discardableResult
    public mutating func append(_ data: Data) -> Bool {
        partial.append(data)
        var completed = false
        var start = partial.startIndex
        while let newline = partial[start...].firstIndex(of: 0x0A) {
            if let text = String(data: partial[start..<newline], encoding: .utf8),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(text)
                completed = true
            }
            start = partial.index(after: newline)
        }
        partial = Data(partial[start...])
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        return completed
    }
}
