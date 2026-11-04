import LampBoardCore
import Foundation
import TestKit

/// A session the person moved to another project (D184).
///
/// D183 keeps a session in the folder it started in whatever its Claude does;
/// the person asked, the same evening, to be able to move one when they mean
/// it. The move is a file on the session's machine, so every screen that reads
/// that machine sees the same move.
enum SessionMovesSuite {

    private static let id = "1287c1a0-3333-4333-8333-333333333333"

    private static func freshHome() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("lbtest-moves-\(UUID().uuidString)").path
    }

    static let suite = TestSuite("Sessions moved by the person", [

        TestCase("A move is written, read back, and taken away") { t in
            let home = freshHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            t.expectNil(SessionMoves.folder(home: home, sessionId: id), "never moved")
            do {
                try SessionMoves.move(sessionId: id, to: "/home/dev/tennis/", started: "/home/dev/analysis", home: home)
            } catch {
                return t.fail("the move was refused: \(error)")
            }
            t.expectEqual(SessionMoves.folder(home: home, sessionId: id), "/home/dev/tennis", "the folder, normalized")
            try? SessionMoves.back(sessionId: id, home: home)
            t.expectNil(SessionMoves.folder(home: home, sessionId: id), "taken back")
            t.expect((try? SessionMoves.back(sessionId: id, home: home)) != nil, "nothing to take back is no error")
        },

        TestCase("Moving a session to the folder it started in is taking the move away") { t in
            let home = freshHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            try? SessionMoves.move(sessionId: id, to: "/home/dev/tennis", started: "/home/dev/analysis", home: home)
            try? SessionMoves.move(sessionId: id, to: "/home/dev/analysis/", started: "/home/dev/analysis", home: home)
            t.expectNil(SessionMoves.folder(home: home, sessionId: id), "no file says it is home")
        },

        TestCase("Only a session id names a file, and only an absolute path is a folder") { t in
            t.expect(SessionMoves.isSafe(sessionId: id), "a UUID")
            for bad in ["", "../token", "a/b", "x y", String(repeating: "a", count: 129)] {
                t.expect(!SessionMoves.isSafe(sessionId: bad), "refused: \(bad.prefix(12))")
            }
            t.expectEqual(SessionMoves.folder(from: "/home/dev/tennis\n"), "/home/dev/tennis", "the first line")
            t.expectNil(SessionMoves.folder(from: "tennis"), "a relative path is no folder")
            t.expectNil(SessionMoves.folder(from: ""), "nor is nothing")
            let home = freshHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            var refused: SessionMoveError?
            do { try SessionMoves.move(sessionId: "../x", to: "/tmp", started: nil, home: home) } catch {
                refused = error as? SessionMoveError
            }
            t.expectEqual(refused, .unsafeSession("../x"), "an unsafe id is refused")
        },

        TestCase("A command finds its session among its ancestors, the nearest one with a file") { t in
            // 900 is the command, 800 its shell, 700 Claude Code; 1 is init.
            let parents = [900: 800, 800: 700, 700: 600, 600: 1]
            let files = [700: id, 600: "outer-session"]
            let found = SessionMoves.ownSession(from: 900, parent: { parents[$0] }, sessionId: { files[$0] })
            t.expectEqual(found?.pid, 700, "Claude Code's process")
            t.expectEqual(found?.sessionId, id, "and its session, not the one around it")
            t.expectNil(SessionMoves.ownSession(from: 900, parent: { parents[$0] }, sessionId: { _ in nil }),
                        "outside any session: nothing, never a guess")
        },
    ])
}

