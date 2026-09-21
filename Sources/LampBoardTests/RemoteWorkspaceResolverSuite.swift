import LampBoardCore
import Foundation
import TestKit

/// Which folder a row on another machine belongs to (D51).
///
/// The case that made this: a session started in `simululator` whose Claude had
/// stepped into `simululator/esperimento`. Every hook said the second, the row
/// was called "esperimento", the window was `simululator [SSH: minisforum]`, and
/// the click found nothing.
enum RemoteWorkspaceResolverSuite {

    private static let host = "node"
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func window(_ folder: String, ide: String = "Visual Studio Code") -> IDEWindow {
        IDEWindow(workspaceFolders: [folder], ideName: ide, pid: 40, lockModifiedAt: now)
    }

    private static func file(_ id: String, cwd: String) -> LiveSession {
        LiveSession(
            pid: 7, sessionId: id, cwd: cwd, entrypoint: "claude-vscode", name: nil, kind: "interactive",
            modifiedAt: now, host: host, context: nil
        )
    }

    private static func resolve(
        cwd: String, id: String = "s1", windows: [IDEWindow] = [], sessions: [LiveSession] = []
    ) -> Workspace {
        RemoteWorkspaceResolver.resolve(
            cwd: cwd, sessionId: id, host: host, windows: windows, sessions: sessions, at: now
        )
    }

    static let suite = TestSuite("Remote workspace resolution", [

        TestCase("The node's window that contains the cwd is the folder, whatever the cwd says") { t in
            let resolved = resolve(
                cwd: "/home/dev/simululator/esperimento",
                windows: [window("/home/dev/simululator"), window("/home/dev/awevents")]
            )
            t.expectEqual(resolved, Workspace(path: "/home/dev/simululator", host: host), "the window's folder")
            t.expectEqual(resolved.name, "simululator", "and its name, which is what the title carries")
        },

        TestCase("Nested windows: the deepest one that contains the cwd wins") { t in
            let resolved = resolve(
                cwd: "/home/dev/simululator/esperimento/run",
                windows: [window("/home/dev/simululator"), window("/home/dev/simululator/esperimento")]
            )
            t.expectEqual(resolved.path, "/home/dev/simululator/esperimento", "deepest")
        },

        // Written once at start and never moved by a `cd`: the second-best record
        // of where the session lives, when the node has no window for it.
        TestCase("Without a window, the session file's folder stands in — if it contains the cwd") { t in
            let resolved = resolve(
                cwd: "/home/dev/simululator/esperimento", id: "s1",
                sessions: [file("s1", cwd: "/home/dev/simululator")]
            )
            t.expectEqual(resolved.path, "/home/dev/simululator", "the file's folder")

            let elsewhere = resolve(
                cwd: "/home/dev/other", id: "s1",
                sessions: [file("s1", cwd: "/home/dev/simululator")]
            )
            t.expectEqual(elsewhere.path, "/home/dev/other", "a cwd outside the file's folder is not folded into it")

            let another = resolve(
                cwd: "/home/dev/simululator/esperimento", id: "s1",
                sessions: [file("s2", cwd: "/home/dev/simululator")]
            )
            t.expectEqual(another.path, "/home/dev/simululator/esperimento", "somebody else's file says nothing about s1")
        },

        TestCase("With neither, the cwd itself is the folder, as it always was") { t in
            let resolved = resolve(cwd: "/home/dev/.notes")
            t.expectEqual(resolved, Workspace(path: "/home/dev/.notes", host: host), "cwd, with the host")
        },

        TestCase("A window of an editor nobody can raise does not claim the row") { t in
            let resolved = resolve(
                cwd: "/home/dev/simululator/esperimento",
                windows: [window("/home/dev/simululator", ide: "SomeEditor")]
            )
            t.expectEqual(resolved.path, "/home/dev/simululator/esperimento", "unsupported window ignored")
        },

        // The probe answers after the row exists — the first hooks arrived before
        // the node had ever been asked — so the row is moved, not recreated: same
        // colour, same history, new folder. A row already where it belongs is
        // left alone, and an unknown id is nothing to do.
        TestCase("A row is rehomed in place, colour and history untouched") { t in
            let moment = Date(timeIntervalSince1970: 1_788_000_000)
            let row = SessionState(
                id: "s1", status: .ready,
                workspace: Workspace(path: "/home/dev/simululator/esperimento", host: host),
                updatedAt: moment, statusSince: moment
            )
            let state = TrafficLightState(sessions: ["s1": row])
            let better = Workspace(path: "/home/dev/simululator", host: host)

            let moved = StateReducer.reduce(state, action: .rehome(sessionId: "s1", workspace: better), now: now)
            t.expectEqual(moved.sessions["s1"]?.workspace, better, "the folder")
            t.expectEqual(moved.sessions["s1"]?.status, .ready, "the colour")
            t.expectEqual(moved.sessions["s1"]?.statusSince, moment, "the history")

            let same = StateReducer.reduce(moved, action: .rehome(sessionId: "s1", workspace: better), now: now)
            t.expectEqual(same, moved, "already there: nothing changes")
            let stranger = StateReducer.reduce(state, action: .rehome(sessionId: "nobody", workspace: better), now: now)
            t.expectEqual(stranger, state, "an unknown row is nothing to do")
        },
    ])
}
