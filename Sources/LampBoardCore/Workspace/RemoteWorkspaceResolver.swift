import Foundation

/// Which folder a session on another machine belongs to.
///
/// Three answers, in order, and the order is the point. The **editor window** on
/// the node whose folder contains the session's `cwd`, read from the node's own
/// lock files exactly as the local resolver reads this Mac's — that is the window
/// the click has to raise, and its name is the row's name. Failing that, the
/// folder the session's **file** names, written once at start and never moved by
/// a `cd`. Failing that, the `cwd` itself, which is what every remote row got
/// before this existed.
///
/// Found on 21 September 2026: a session started in `simlab`, whose Claude
/// had stepped into `simlab/experiment`, reported the second in every hook.
/// The row was called "experiment", the window was called `simlab [SSH:
/// devmachine]`, and the click found nothing. The session beside it worked
/// because it had never left its root (D51).
///
/// The file's folder holds wherever the `cwd` went, not only below it (D183).
/// Found on 4 November 2026: a session started in its project's folder had
/// stepped into a data folder under `~/.local/share`, outside the project, to
/// read what it was analysing. The phone, which reads the file, kept it in its
/// project; the Mac, which folded a `cwd` into the file's folder only from
/// below, opened a project of its own named after the data folder.
///
/// A session the person moved to another project goes where they moved it
/// (D184), before anything else is asked: that is the one move that is meant.
public enum RemoteWorkspaceResolver {

    /// - Parameters:
    ///   - cwd: what the hook reported.
    ///   - sessionId: whose hook it was, to find its file among `sessions`.
    ///   - host: the machine, carried into the workspace.
    ///   - windows: the node's editor windows, as its last probe reported them.
    ///   - sessions: the node's live sessions, from the same probe.
    public static func resolve(
        cwd: String,
        sessionId: String,
        host: String,
        windows: [IDEWindow],
        sessions: [LiveSession],
        at now: Date
    ) -> Workspace {
        let file = own(sessionId, host: host, in: sessions)
        // Moved by the person (D184): the folder they named, or the window
        // over there that contains it — before any window claims the `cwd`.
        if let moved = file?.movedTo {
            let window = WorkspaceResolver.resolve(cwd: moved, in: windows, at: now)
            return Workspace(path: window?.path ?? moved, host: host)
        }
        if let window = WorkspaceResolver.resolve(cwd: cwd, in: windows, at: now) {
            return Workspace(path: window.path, host: host)
        }
        if let file, !file.cwd.isEmpty {
            return Workspace(path: file.cwd, host: host)
        }
        return Workspace(path: cwd, host: host)
    }

    /// Whether a row found on `host`, which otherwise keeps its folder through
    /// every look, is to be resolved again (D184): its session was moved by the
    /// person, or was and no longer is — its folder is then neither the one its
    /// file names nor one a window over there gave it, and resolving it again
    /// gives the same answer in every other case.
    public static func mayRehome(sessionId: String, workspace: Workspace, host: String,
                                 sessions: [LiveSession]) -> Bool {
        guard let file = own(sessionId, host: host, in: sessions) else { return false }
        return file.movedTo != nil || file.cwd != workspace.path
    }

    /// `sessionId`'s file among `sessions`. A file read with no host is the
    /// reading machine's own: `lampd` reads its machine as the phone would, and
    /// names it only in the rows it builds — without this its sessions would
    /// never find their files, and a move made there would move nothing (D184).
    private static func own(_ sessionId: String, host: String, in sessions: [LiveSession]) -> LiveSession? {
        sessions.first { $0.sessionId == sessionId && ($0.host == host || $0.host == nil) }
    }
}
