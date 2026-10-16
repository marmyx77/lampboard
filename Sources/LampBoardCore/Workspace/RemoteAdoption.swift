import Foundation

/// Which sessions another machine's probe reports become rows before they have
/// said anything (D137).
///
/// Until 1.3.1 a remote session earned its row only by speaking through the
/// tunnel. So after LampBoard restarted (an update is enough), every session
/// resting on another machine was missing from the column until it next did
/// something, and Open here, which needs the row, could not reach it. This
/// machine's sessions never had that gap: their files are read at every pass.
/// Now the other machine's are too, by the same rule, from what its probe sends.
public enum RemoteAdoption {

    /// A terminal's session (an editor's keeps arriving through its own hooks
    /// and windows), not one in the background, with a conversation in it, and
    /// only while terminal sessions are shown at all.
    public static func adoptable(_ live: [LiveSession], showsTerminalSessions: Bool) -> [LiveSession] {
        guard showsTerminalSessions else { return [] }
        return live.filter { session in
            session.host != nil
                && session.deservesTrafficLight
                && session.hasTranscript
                && TmuxPlace.isPlaceable(entrypoint: session.entrypoint, isBackground: session.isBackground)
        }
    }

    /// The row an adoptable session starts as: idle unless Claude Code says
    /// `busy` (D141) — working while its turn is open, waiting (blue) once the
    /// turn ended with background work still registered
    /// (`LiveSession.statusFromFile`) — a terminal's row unless said otherwise,
    /// named as Claude Code names it there. The phone's reading of a machine
    /// without `lampd` makes its rows with this same rule (D176).
    public static func adopted(_ session: LiveSession, in workspace: Workspace, origin: SessionOrigin = .terminal) -> SessionState {
        SessionState(
            id: session.sessionId, status: session.statusFromFile, workspace: workspace,
            updatedAt: session.modifiedAt, statusSince: session.modifiedAt,
            entrypoint: session.entrypoint, origin: origin, title: session.name
        )
    }
}
