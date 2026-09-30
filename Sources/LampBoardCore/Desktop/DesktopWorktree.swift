import Foundation

/// The name of a row the Claude application runs in a worktree of its own.
///
/// WHY
/// The application can give each conversation its own linked worktree, created
/// under `.claude/worktrees/` with a generated name — `vigilant-ramanujan-790712`
/// — on a branch `claude/` of the same name. The row is named after its folder,
/// like every row, so the column filled with names nobody chose and that say
/// nothing about which project they belong to: met on 30 September 2026, a
/// conversation on the `Exit` repository read as `vigilant-ramanujan-790712`.
///
/// So such a row reads `Exit · vigilant-ramanujan`: the project first, because
/// that is what a person looks for, then the worktree without its numeric tail,
/// which is what tells two of the same project apart. Only the application's
/// rows: an editor row's name is its window's title, and changing it there would
/// make the row disagree with the window it raises.
public enum DesktopWorktree {

    /// The name to show, or `nil` to keep the folder's.
    ///
    /// - Parameters:
    ///   - folder: the last component of the session's folder.
    ///   - git: what the session's repository says of itself; `repo` is the
    ///     **main** repository's name for a linked worktree.
    public static func label(folder: String, git: GitIdentity?) -> String? {
        guard let git, git.isWorktree,
              let repo = git.repo?.trimmed.nilIfEmpty,
              repo != folder
        else { return nil }
        return repo + " · " + trimmingSerial(folder)
    }

    /// `vigilant-ramanujan-790712` → `vigilant-ramanujan`. A name made only of
    /// the number, or with no dash, is kept whole: there is nothing else to show.
    static func trimmingSerial(_ folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let tail = folder[folder.index(after: dash)...]
        let head = folder[..<dash]
        guard !tail.isEmpty, !head.isEmpty, tail.allSatisfy(\.isNumber) else { return folder }
        return String(head)
    }
}
