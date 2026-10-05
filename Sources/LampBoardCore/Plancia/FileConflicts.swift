import Foundation

/// Two live sessions writing the same file of the same checkout (UX §4, the
/// row's ⚠): today found at the merge, here while it happens. From the tools the
/// companion mods report — a write's absolute path is the same file only in the
/// same checkout, so a worktree of the same repository is not a conflict here.
public enum FileConflicts {

    public struct Conflict: Sendable, Equatable {
        public let file: String
        public let with: String

        public init(file: String, with: String) {
            self.file = file
            self.with = with
        }
    }

    /// How recent a write still counts.
    public static let window: TimeInterval = 2 * 60 * 60
    /// The tools that write a file, by the names Claude Code gives them.
    static let writers: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// For each live session, the files it shares with another, and with whom.
    public static func find(_ logs: [String: SessionActivity], live: Set<String>, now: Date) -> [String: [Conflict]] {
        let since = now.addingTimeInterval(-window)
        var writers: [String: Set<String>] = [:]
        for (session, log) in logs where live.contains(session) {
            for entry in log.entries where entry.at >= since {
                guard case .tool(let name, let detail?) = entry.kind, Self.writers.contains(name), detail.hasPrefix("/") else { continue }
                writers[detail, default: []].insert(session)
            }
        }
        var found: [String: [Conflict]] = [:]
        for (file, sessions) in writers where sessions.count > 1 {
            for session in sessions {
                found[session, default: []] += sessions.subtracting([session]).sorted().map { Conflict(file: file, with: $0) }
            }
        }
        return found.mapValues { $0.sorted { ($0.with, $0.file) < ($1.with, $1.file) } }
    }

    /// The latest write of `path` by another live session in the window, for the
    /// radar (§4.4): before a session writes it, whether somebody else just did.
    /// A path as the activity log keeps it — masked, flattened, cut — so that the
    /// radar compares like with like. Two long paths that agree up to the cut read
    /// as one, which can only cost a question.
    public static func recordedForm(_ path: String) -> String? {
        ModReport.detail(path).map(SessionActivity.line)
    }

    public static func lastWriter(of path: String, besides session: String, logs: [String: SessionActivity],
                                  live: Set<String>, now: Date) -> (session: String, at: Date)? {
        guard let path = recordedForm(path) else { return nil }
        let since = now.addingTimeInterval(-window)
        var latest: (session: String, at: Date)?
        for (other, log) in logs where other != session && live.contains(other) {
            for entry in log.entries where entry.at >= since {
                guard case .tool(let name, let detail?) = entry.kind, writers.contains(name), detail == path else { continue }
                if latest.map({ entry.at > $0.at }) ?? true { latest = (other, entry.at) }
            }
        }
        return latest
    }
}
