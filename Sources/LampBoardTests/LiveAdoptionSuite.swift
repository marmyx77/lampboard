import LampBoardCore
import Foundation
import TestKit

/// Where a session nobody announced goes, by the rules the Mac's store applied
/// and `lampd` will apply to its own machine.
enum LiveAdoptionSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private static let window = IDEWindow(workspaceFolders: ["/work/alpha"], ideName: "Visual Studio Code", pid: 10, lockModifiedAt: t0)

    private static func live(cwd: String = "/work/alpha/src", kind: String? = "interactive", busy: Bool = false,
                             word: LiveSession.FileStatus? = nil, turnIsOpen: Bool? = nil) -> LiveSession {
        LiveSession(pid: 4242, sessionId: "00000000-0000-4000-8000-000000000001", cwd: cwd, entrypoint: "cli",
                    name: "alpha-7", kind: kind, modifiedAt: t0, fileStatus: word ?? (busy ? .busy : .idle), turnIsOpen: turnIsOpen)
    }

    private static let never: (LiveSession) -> Bool = { _ in false }
    private static let always: (LiveSession) -> Bool = { _ in true }

    static let suite = TestSuite("Adopting live sessions", [

        TestCase("A session inside an editor window's folder is that window's row") { t in
            let place = LiveAdoption.placement(of: live(), windows: [window], showsTerminalSessions: false, at: t0, hasOwnFolder: never)
            t.expectEqual(place?.workspace.path, "/work/alpha", "the window's folder")
            t.expectEqual(place?.origin, .editor, "an editor row")
        },

        TestCase("In tmux it is its own folder's row, whatever window contains it") { t in
            let place = LiveAdoption.placement(of: live(), windows: [window], showsTerminalSessions: false, at: t0, hasOwnFolder: always)
            t.expectEqual(place?.workspace.path, "/work/alpha/src", "its own folder")
            t.expectEqual(place?.origin, .terminal, "a terminal row")
        },

        TestCase("A background session's place is the panel, and its process tree is not walked") { t in
            var asked = false
            let place = LiveAdoption.placement(of: live(kind: AppConfig.backgroundSessionKind), windows: [window],
                                               showsTerminalSessions: false, at: t0, hasOwnFolder: { _ in asked = true; return false })
            t.expectEqual(place?.origin, .background, "background")
            t.expectEqual(place?.workspace.path, "/work/alpha/src", "its folder")
            t.expect(!asked, "the walk is skipped when the answer cannot matter")
        },

        TestCase("Unclaimed, it has a row only while terminal sessions are shown") { t in
            let elsewhere = live(cwd: "/elsewhere")
            t.expectNil(LiveAdoption.placement(of: elsewhere, windows: [window], showsTerminalSessions: false, at: t0, hasOwnFolder: never),
                        "hidden")
            t.expectEqual(LiveAdoption.placement(of: elsewhere, windows: [window], showsTerminalSessions: true, at: t0, hasOwnFolder: never)?.origin,
                          .terminal, "shown (D25)")
        },

        TestCase("A row found by its file is idle unless Claude Code says busy") { t in
            let quiet = LiveAdoption.adopted(live(), in: Workspace(path: "/work/alpha"), origin: .editor)
            t.expectEqual(quiet.status, .idle, "not inferred to be working")
            t.expectEqual(quiet.updatedAt, t0, "the file's time is kept")
            t.expectEqual(LiveAdoption.adopted(live(busy: true), in: Workspace(path: "/work/alpha"), origin: .editor).status,
                          .working, "Claude Code's own busy (D141)")
        },

        TestCase("A hook's live file decides its home the same way") { t in
            t.expectNil(LiveAdoption.home(of: nil, claimed: false, showsTerminalSessions: true, hasOwnFolder: always), "no file, no home")
            t.expectEqual(LiveAdoption.home(of: live(kind: AppConfig.backgroundSessionKind), claimed: true,
                                            showsTerminalSessions: false, hasOwnFolder: never)?.origin, .background, "background")
            t.expectEqual(LiveAdoption.home(of: live(), claimed: true, showsTerminalSessions: false, hasOwnFolder: always)?.origin,
                          .terminal, "tmux wins over the claim")
            t.expectNil(LiveAdoption.home(of: live(), claimed: true, showsTerminalSessions: true, hasOwnFolder: never),
                        "claimed by a window: the window's")
            t.expectEqual(LiveAdoption.home(of: live(), claimed: false, showsTerminalSessions: true, hasOwnFolder: never)?.origin,
                          .terminal, "unclaimed, terminals shown")
        },

        TestCase("Another machine's session starts as a named terminal row") { t in
            let row = RemoteAdoption.adopted(live(busy: true), in: Workspace(path: "/work/alpha", host: "example-node"))
            t.expectEqual(row.origin, .terminal, "terminal")
            t.expectEqual(row.title, "alpha-7", "named as Claude Code names it")
            t.expectEqual(row.status, .working, "busy")
        },

        // Busy in Claude Code's file with the turn closed in the tail: background
        // work registered, which the Mac's hooks paint blue. Read over ssh, the
        // same blue: not yellow (the file alone), not resting (the build 2 collapse).
        TestCase("Busy with its turn closed is paused; with it open or unknown, working; not busy, idle") { t in
            let place = Workspace(path: "/work/alpha", host: "example-node")
            t.expectEqual(RemoteAdoption.adopted(live(busy: true, turnIsOpen: false), in: place).status, .waiting,
                          "background work registered: blue, as on the Mac")
            t.expectEqual(RemoteAdoption.adopted(live(busy: true, turnIsOpen: true), in: place).status, .working, "a turn open")
            t.expectEqual(RemoteAdoption.adopted(live(busy: true), in: place).status, .working, "no turn in the tail: the file")
            t.expectEqual(RemoteAdoption.adopted(live(turnIsOpen: false), in: place).status, .idle, "not busy: resting")
            t.expectEqual(LiveAdoption.adopted(live(busy: true, turnIsOpen: false), in: Workspace(path: "/work/alpha"), origin: .editor).status,
                          .waiting, "the same rule for a session found by its file here")
        },

        // Claude Code 2.1.300 writes `shell` once the turn is over and only a
        // background shell runs, and `waiting` while something waits for the
        // person. The phone re-reads the file at every look and takes amber from
        // it; the Mac keeps its rows by their hooks, which carry the question and
        // its way back, so amber from the file is not lit there.
        TestCase("Shell is paused; waiting is amber on a row read again and again, never on a row its hooks keep") { t in
            let place = Workspace(path: "/work/alpha", host: "example-node")
            for open in [Bool?.none, true, false] {
                t.expectEqual(RemoteAdoption.adopted(live(word: .shell, turnIsOpen: open), in: place).status, .waiting,
                              "a background shell, turn \(String(describing: open)): blue")
            }
            t.expectEqual(RemoteAdoption.adopted(live(word: .waiting), in: place).status, .awaiting, "the phone: amber")
            t.expectEqual(RemoteAdoption.adopted(live(word: .waiting), in: place, heard: true).status, .idle,
                          "the Mac adopting it: amber is the hooks'")
            t.expectEqual(RemoteAdoption.adopted(live(word: .shell), in: place, heard: true).status, .waiting, "blue on the Mac too")
            t.expectEqual(LiveAdoption.adopted(live(word: .waiting), in: Workspace(path: "/work/alpha"), origin: .editor).status,
                          .idle, "a session found by its file here: amber is the hooks'")
            t.expectEqual(LiveAdoption.adopted(live(word: .shell), in: Workspace(path: "/work/alpha"), origin: .editor).status,
                          .waiting, "and a background shell is blue here as well")
            t.expectEqual(RemoteAdoption.adopted(live(word: .unrecognised("dreaming")), in: place).status, .idle,
                          "a word not known yet: resting, never yellow")
            let idle = TrafficLightState(sessions: ["s": SessionState(id: "s", status: .idle, workspace: place, updatedAt: t0, statusSince: t0)])
            t.expectEqual(StateReducer.reduce(idle, action: .busy(sessionId: "s", status: .awaiting), now: t0).sessions["s"]?.status,
                          .idle, "the Mac's reducer lights no amber from the file")
        },
    ])
}
