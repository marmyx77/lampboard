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
/// Found on 21 September 2026: a session started in `simululator`, whose Claude
/// had stepped into `simululator/esperimento`, reported the second in every hook.
/// The row was called "esperimento", the window was called `simululator [SSH:
/// minisforum]`, and the click found nothing. The session beside it worked
/// because it had never left its root (D51).
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
        if let window = WorkspaceResolver.resolve(cwd: cwd, in: windows, at: now) {
            return Workspace(path: window.path, host: host)
        }
        if let file = sessions.first(where: { $0.sessionId == sessionId && $0.host == host }),
           PathNormalizer.isDescendant(PathNormalizer.normalize(cwd), of: PathNormalizer.normalize(file.cwd)) {
            return Workspace(path: file.cwd, host: host)
        }
        return Workspace(path: cwd, host: host)
    }
}
