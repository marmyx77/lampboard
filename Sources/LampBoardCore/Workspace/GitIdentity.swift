import Foundation

/// What repository and branch a session is working in.
///
/// One value rather than three loose fields, because the three only mean anything
/// together: a branch with no repository names nothing, and the worktree flag is a
/// statement *about* the repository name — that it was taken from the main
/// repository rather than from the folder the session is actually sitting in.
///
/// **Resolved by the hook script, never here.** The app must not read under a
/// session's working directory: macOS gates Desktop, Documents, Downloads and
/// network volumes as separate grants, so a `<cwd>/.git/HEAD` read from the app
/// pops a folder-access prompt the first time a session appears under any category
/// not yet granted — and on a poll it recurs rather than asking once. The script
/// runs in the user's own shell, in the session's directory, under the terminal's
/// grants, and ships the answer in three headers.
///
/// **Read at a session start and at the end of each turn.** The start alone is not
/// enough: a brand new session has written no transcript yet, so its start earns no
/// row (D44) and the identity would go in the bin with it — only a *resumed*
/// session would ever show a branch. `Stop` lands on a row that certainly exists.
///
/// `Stop` and not `UserPromptSubmit`, which sits between the person pressing enter
/// and Claude starting; `Stop` fires when the session is idle by definition. The
/// bonus is that a `git checkout` half way through reaches the row within one turn.
/// One `git` invocation per turn, off the critical path — not one per tool call.
public struct GitIdentity: Equatable, Sendable, Codable {

    /// The repository's name. For a linked worktree this is the **main**
    /// repository, not the worktree folder: it is the name the person thinks in.
    public let repo: String?

    /// The branch checked out when the session started. Absent for a detached head
    /// and for a repository whose first commit does not exist yet — both real
    /// states, and neither of them a name to display.
    public let branch: String?

    /// `true` when the session is inside a linked worktree.
    public let isWorktree: Bool

    public init(repo: String?, branch: String?, isWorktree: Bool = false) {
        self.repo = repo
        self.branch = branch
        self.isWorktree = isWorktree
    }

    /// `nil` unless at least one of the two names says something, so that a caller
    /// cannot end up holding an identity that identifies nothing.
    public static func from(repo: String?, branch: String?, worktree: String?) -> GitIdentity? {
        let repo = repo?.trimmed.nilIfEmpty
        let branch = branch?.trimmed.nilIfEmpty
        guard repo != nil || branch != nil else { return nil }
        return GitIdentity(
            repo: repo,
            branch: branch,
            // Any value at all means yes. The script sends the header only when it
            // has decided the answer is true, and never sends it otherwise.
            isWorktree: worktree?.trimmed.nilIfEmpty != nil
        )
    }

    /// One line for the card: `repo · branch`, with the worktree said in words.
    ///
    /// The worktree is spelled out rather than marked with a glyph because it
    /// changes what the **repository name means** — it is the main repository, not
    /// the folder the session is in — and a symbol cannot carry that.
    public var summary: String? {
        var parts: [String] = []
        if let repo { parts.append(repo) }
        if let branch { parts.append(branch) }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: " · ")
        return isWorktree ? "\(line) (worktree)" : line
    }
}
