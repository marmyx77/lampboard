import Foundation

/// Matches a Claude Code session's `cwd` to the VS Code window hosting it.
///
/// This is where a session's **editor** row is decided: if no VS Code window
/// contains that folder, no editor hosts the session. What happens then is the
/// store's decision, not this one's — with terminal sessions on (D25) the
/// session's own folder becomes its place; off, the signal is dropped.
public enum WorkspaceResolver {
    /// Returns the workspace containing `cwd`, or `nil`.
    ///
    /// When several workspaces match (nested folders open in different windows)
    /// the deepest one wins: it is the one that describes the session best.
    ///
    /// - Parameters:
    ///   - onlySupported: when `true`, discards windows belonging to editors we
    ///     don't know how to bring to the front. A row you can see with a click
    ///     that doesn't work is worse than no row at all.
    public static func resolve(
        cwd: String,
        in windows: [IDEWindow],
        at now: Date,
        onlySupported: Bool = true
    ) -> Workspace? {
        window(hosting: cwd, in: windows, at: now, onlySupported: onlySupported)
            .map { Workspace(path: $0.folder) }
    }

    /// The window hosting `cwd`, along with the exact folder that won.
    ///
    /// Needed by the click, which has to know **which editor** to raise: VS Code's
    /// bundle identifier and Cursor's are different, and using the wrong one brings
    /// the wrong application to the front.
    public static func window(
        hosting cwd: String,
        in windows: [IDEWindow],
        at now: Date,
        onlySupported: Bool = true
    ) -> (window: IDEWindow, folder: String)? {
        let normalizedCwd = PathNormalizer.normalize(cwd)
        guard !normalizedCwd.isEmpty else { return nil }

        // No freshness filter here any more. Whoever read these locks has already
        // confirmed them against the editor's process, which is the only check
        // that means anything — see `IDEWindow.isUsable`.
        let candidates = windows
            .filter { !onlySupported || $0.isSupported }
            .flatMap { window in
                // Either spelling of the folder hosts the session, and the row
                // takes the window's: see `IDEWindow.resolvedFolders`.
                zip(window.workspaceFolders, window.resolvedFolders)
                    .filter { folder, resolved in
                        PathNormalizer.isDescendant(normalizedCwd, of: folder)
                            || PathNormalizer.isDescendant(normalizedCwd, of: resolved)
                    }
                    .map { (window: window, folder: $0.0) }
            }

        // The longest path is the most specific match.
        return candidates.max { $0.folder.count < $1.folder.count }
    }
}
