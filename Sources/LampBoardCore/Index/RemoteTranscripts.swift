import Foundation

/// The conversations of another machine for ⌘K (M7): their transcripts listed
/// and read through the panel's ssh, only under `~/.claude/projects`, only the
/// bytes added since the last pass. One `sh -c` script each, every value
/// quoted, on the machine's own `find`, `stat`, `tail` and `head` (GNU or BSD).
public enum RemoteTranscripts {

    /// One transcript there: where, how big, when it last changed.
    public struct File: Equatable, Sendable {
        public let path: String
        public let size: Int
        public let modified: Date

        public init(path: String, size: Int, modified: Date) {
            self.path = path
            self.size = size
            self.modified = modified
        }

        /// The conversation's id: the file's name, a UUID.
        public var sessionId: String { String((path as NSString).lastPathComponent.dropLast(".jsonl".count)) }
    }

    /// The most files a listing returns.
    public static let mostFiles = 2000

    /// The transcripts changed in the last `days`, one line each: size, time,
    /// path (relative to `~/.claude/projects`).
    public static func list(days: Int = 90) -> String {
        "cd \"$HOME/.claude/projects\" 2>/dev/null || exit 0; "
            + "find . -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mtime -\(max(1, days)) 2>/dev/null | head -n \(mostFiles) | "
            + "while IFS= read -r f; do s=$(wc -c < \"$f\" | tr -d ' '); "
            + "m=$(stat -c %Y \"$f\" 2>/dev/null || stat -f %m \"$f\" 2>/dev/null); echo \"$s $m $f\"; done"
    }

    /// The listing read back; a line that is not one is dropped.
    public static func parse(_ output: String) -> [File] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let size = Int(parts[0]), let time = Double(parts[1]),
                  isTranscript(parts[2]) else { return nil }
            return File(path: parts[2], size: size, modified: Date(timeIntervalSince1970: time))
        }
        .sorted { $0.modified > $1.modified }
    }

    /// `./<project folder>/<uuid>.jsonl`, and nothing else: no `..`, no other
    /// folder, no name Claude Code would not have written.
    public static func isTranscript(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == ".", !parts[1].isEmpty, parts[1] != ".", parts[1] != "..",
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              parts[2].hasSuffix(".jsonl") else { return false }
        let id = parts[2].dropLast(".jsonl".count)
        return id.count == 36 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// `limit` bytes of a transcript from `offset`; `nil` for a path that is
    /// not one, or a link (which could lead anywhere on that machine).
    public static func read(path: String, from offset: Int, limit: Int) -> String? {
        guard isTranscript(path), offset >= 0, limit > 0 else { return nil }
        let quoted = RemoteProject.quote(path)
        return "cd \"$HOME/.claude/projects\" && [ -f \(quoted) ] && [ ! -L \(quoted) ] && "
            + "tail -c +\(offset + 1) -- \(quoted) | head -c \(limit)"
    }

    /// The key a remote transcript has in the index: never a path on this Mac.
    public static func key(host: String, path: String) -> String { "ssh://\(host)/\(path)" }
}
