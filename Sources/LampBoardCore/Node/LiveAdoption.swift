import Foundation

/// Where a session nobody announced belongs, and the row it becomes (D1, D19,
/// D25, D44, D141).
///
/// Taken out of the Mac's `StateStore` as pure functions (W1 of the mobile plan):
/// `lampd` adopts the sessions on its own machine by the same rules, from the
/// same files, with no window of its own to ask. What a function cannot decide
/// alone — whether a process runs in tmux or in LampBoard's terminal, which
/// takes a walk of the process tree — it is handed as a closure, asked only
/// when the answer matters, as the store asked it.
public enum LiveAdoption {

    /// The folder and origin of a row for a hook that came from `live`'s
    /// session, or `nil` to leave the signal to the editor windows.
    ///
    /// - A background session's place is the panel, whatever window has its
    ///   folder open (AV1).
    /// - In tmux or in LampBoard's own terminal, its own folder, whatever editor
    ///   window contains it: one open on the home folder claimed every project.
    /// - Unclaimed, with terminal sessions shown (D25), its own folder too.
    public static func home(
        of live: LiveSession?, claimed: Bool, showsTerminalSessions: Bool,
        hasOwnFolder: (LiveSession) -> Bool
    ) -> (workspace: Workspace, origin: SessionOrigin)? {
        guard let live else { return nil }
        if live.isBackground { return (Workspace(path: live.cwd), .background) }
        if hasOwnFolder(live) { return (Workspace(path: live.cwd), .terminal) }
        if !claimed && showsTerminalSessions { return (Workspace(path: live.cwd), .terminal) }
        return nil
    }

    /// Where a session found by its file goes: the editor window that contains
    /// its folder, or its own folder when it has one (background, tmux,
    /// LampBoard's terminal) or when terminal sessions are shown; `nil` when it
    /// has no place in the column.
    public static func placement(
        of session: LiveSession, windows: [IDEWindow], showsTerminalSessions: Bool, at now: Date,
        hasOwnFolder: (LiveSession) -> Bool
    ) -> (workspace: Workspace, origin: SessionOrigin)? {
        let inTmux = !session.isBackground && hasOwnFolder(session)
        let resolved = session.isBackground || inTmux
            ? nil : WorkspaceResolver.resolve(cwd: session.cwd, in: windows, at: now)
        // The file is the anchor, so no `cd` can move the row.
        guard let workspace = resolved
            ?? (session.isBackground || inTmux || showsTerminalSessions ? Workspace(path: session.cwd) : nil) else {
            return nil
        }
        let origin: SessionOrigin = session.isBackground ? .background : resolved == nil ? .terminal : .editor
        return (workspace, origin)
    }

    /// The row a session found by its file starts as.
    ///
    /// `idle` unless Claude Code itself says `busy` (D141): what a session never
    /// seen is doing is not known, and this is where that is said. Inferring
    /// "working" from a transcript that moved lit a whole column yellow after a
    /// reboot, when every session was resumed at once. The time, on the other
    /// hand, is evidence, and is kept.
    public static func adopted(_ session: LiveSession, in workspace: Workspace, origin: SessionOrigin) -> SessionState {
        SessionState(
            id: session.sessionId,
            status: session.isBusy ? .working : .idle,
            workspace: workspace,
            updatedAt: session.modifiedAt,
            statusSince: session.modifiedAt,
            entrypoint: session.entrypoint,
            origin: origin
        )
    }
}
