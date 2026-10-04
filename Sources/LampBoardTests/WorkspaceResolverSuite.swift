import LampBoardCore
import Foundation
import TestKit

enum WorkspaceResolverSuite {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func window(
        _ folders: [String],
        ide: String = "Visual Studio Code",
        ageInDays: Double = 0
    ) -> IDEWindow {
        IDEWindow(
            workspaceFolders: folders,
            ideName: ide,
            pid: 5501,
            lockModifiedAt: now.addingTimeInterval(-ageInDays * 86_400)
        )
    }

    static let suite = TestSuite("Workspace resolution", [

        TestCase("Resolves the exact folder") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/lampboard",
                in: [window(["/Users/dev/Development/lampboard"])],
                at: now
            )
            t.expectEqual(result, Workspace(path: "/Users/dev/Development/lampboard"))
        },

        TestCase("Resolves a subfolder") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/lampboard/Sources/Core",
                in: [window(["/Users/dev/Development/lampboard"])],
                at: now
            )
            t.expectEqual(result?.name, "lampboard")
        },

        TestCase("With nested workspaces the deepest match wins") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/dev/monorepo/apps/web/src",
                in: [
                    window(["/Users/dev/dev/monorepo"]),
                    window(["/Users/dev/dev/monorepo/apps/web"]),
                ],
                at: now
            )
            t.expectEqual(result?.name, "web")
        },

        // A folder opened through a link: the window says the link, the kernel
        // hands the session the folder it points at. The row keeps the window's
        // name, which is what its title says and what the click looks for.
        TestCase("A session under the folder a window's link points at is that window's") { t in
            let linked = IDEWindow(
                workspaceFolders: ["/Users/dev/Development/livenotes"],
                ideName: "Visual Studio Code", pid: 5501, lockModifiedAt: now,
                resolvedFolders: ["/Users/dev/Development/voicedesk"]
            )
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/voicedesk/engine", in: [linked], at: now
            )
            t.expectEqual(result, Workspace(path: "/Users/dev/Development/livenotes"))
        },

        // The same, on a real disk: the link is followed when the window is read.
        TestCase("A window read from disk follows the link its folder is") { t in
            let root = URL(fileURLWithPath: CanonicalPath.of(NSTemporaryDirectory()))
                .appendingPathComponent("lampboard-link-\(UUID().uuidString)")
            let real = root.appendingPathComponent("voicedesk")
            let link = root.appendingPathComponent("livenotes")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            } catch {
                return t.fail("could not build the fixture: \(error)")
            }
            let read = window([link.path]).resolvingLinks()
            t.expectEqual(read.resolvedFolders, [real.path], "resolved")
            t.expectEqual(
                WorkspaceResolver.resolve(cwd: real.path, in: [read], at: now),
                Workspace(path: link.path)
            )
        },

        TestCase("A window nobody resolved matches exactly as before") { t in
            t.expectNil(WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/voicedesk",
                in: [window(["/Users/dev/Development/livenotes"])], at: now
            ))
        },

        TestCase("No match returns nil") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/elsewhere",
                in: [window(["/Users/dev/Development/lampboard"])],
                at: now
            )
            t.expectNil(result)
        },

        // The resolver no longer judges whether a lock is orphaned — that moved to
        // `IDEWindow.isUsable`, tested below, because the answer needs to know
        // which processes are running and only the shell can ask. What the
        // resolver must still do is trust the list it is handed: filtering by age
        // here as well made a thirty-day-old lock unusable even when its editor
        // was demonstrably running, which is how five projects disappeared.
        TestCase("An old lock still resolves — age is not the resolver's business") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/lampboard",
                in: [window(["/Users/dev/Development/lampboard"], ageInDays: 30)],
                at: now
            )
            t.expectNotNil(result, "the caller already confirmed this window")
        },

        TestCase("Accepts Cursor, which we know how to raise") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/lampboard",
                in: [window(["/Users/dev/Development/lampboard"], ide: "Cursor")],
                at: now
            )
            // Cursor is a VS Code fork and has the same Claude Code extension:
            // discarding it was not a choice, it was a side effect of the check
            // on the name.
            t.expectNotNil(result)
        },

        TestCase("Ignores editors we don't know how to bring to the front") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/lampboard",
                in: [window(["/Users/dev/Development/lampboard"], ide: "Emacs Deluxe 2031")],
                at: now
            )
            // A row you can see with a click that doesn't work is worse than no
            // row: it teaches you not to trust the column.
            t.expectNil(result)
        },

        TestCase("Recognizes the VS Code Insiders build too") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/Development/lampboard",
                in: [window(
                    ["/Users/dev/Development/lampboard"],
                    ide: "Visual Studio Code - Insiders"
                )],
                at: now
            )
            t.expectNotNil(result)
        },

        TestCase("Says which editor hosts the folder") { t in
            let found = WorkspaceResolver.window(
                hosting: "/Users/dev/Development/lampboard/Sources",
                in: [window(["/Users/dev/Development/lampboard"], ide: "Cursor")],
                at: now
            )
            // Needed by the click: Cursor's bundle identifier differs from
            // VS Code's, and using the wrong one brings the wrong application
            // to the front.
            t.expectEqual(found?.window.kind, .cursor, "editor")
            t.expectEqual(found?.folder, "/Users/dev/Development/lampboard", "folder")
        },

        TestCase("Handles a window with several folders") { t in
            let result = WorkspaceResolver.resolve(
                cwd: "/Users/dev/dev/backend/api",
                in: [window(["/Users/dev/dev/frontend", "/Users/dev/dev/backend"])],
                at: now
            )
            t.expectEqual(result?.name, "backend")
        },

        TestCase("The workspace name is the basename") { t in
            t.expectEqual(Workspace(path: "/Users/dev/Development/lampboard").name, "lampboard")
            t.expectEqual(Workspace(path: "/Users/dev/Development/lampboard/").name, "lampboard")
        },
    ])
}

enum IDELockParserSuite {

    private static let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static let suite = TestSuite("Reading the IDE lock files", [

        // Payload copied from a real lock in ~/.claude/ide/.
        TestCase("Decodes a real lock") { t in
            let data = Data("""
            {"pid":5501,"workspaceFolders":["/Users/dev/Development/lampboard"],
             "ideName":"Visual Studio Code","transport":"ws","runningInWindows":false,
             "authToken":"650b7830-e317-4c7f-a195-aefb7734385c"}
            """.utf8)

            guard let window = try? IDELockParser.parse(data: data, modifiedAt: modifiedAt) else {
                return t.fail("decoding the lock failed")
            }
            t.expectEqual(window.pid, 5501, "pid")
            t.expectEqual(window.workspaceFolders, ["/Users/dev/Development/lampboard"], "folders")
            t.expect(window.isVSCode, "must be recognized as VS Code")
        },

        TestCase("Rejects malformed JSON") { t in
            t.expectThrows(IDELockError.invalidJSON) {
                _ = try IDELockParser.parse(data: Data("{".utf8), modifiedAt: modifiedAt)
            }
        },

        TestCase("Rejects a lock without workspaceFolders") { t in
            let data = Data(#"{"pid":1,"ideName":"Visual Studio Code"}"#.utf8)
            t.expectThrows(IDELockError.missingWorkspaceFolders) {
                _ = try IDELockParser.parse(data: data, modifiedAt: modifiedAt)
            }
        },

        TestCase("Rejects an empty workspaceFolders") { t in
            let data = Data(#"{"pid":1,"workspaceFolders":[],"ideName":"Visual Studio Code"}"#.utf8)
            t.expectThrows(IDELockError.missingWorkspaceFolders) {
                _ = try IDELockParser.parse(data: data, modifiedAt: modifiedAt)
            }
        },

        TestCase("Drops the relative paths from the list") { t in
            let data = Data("""
            {"pid":1,"workspaceFolders":["relative","/absolute"],"ideName":"Visual Studio Code"}
            """.utf8)
            let window = try? IDELockParser.parse(data: data, modifiedAt: modifiedAt)
            t.expectEqual(window?.workspaceFolders, ["/absolute"], "filtered folders")
        },
    ])
}

/// Which lock files still describe a window that exists.
///
/// The rule used to be the file's age, and that was wrong in a way that hid five
/// projects for days: a lock is written once, when the window connects, and never
/// touched again — so its timestamp measures how long the window has been open.
/// Leaving windows open for a fortnight is normal.
enum IDELockLivenessSuite {

    private static let now = Date()

    private static func lock(pid: Int, ageInDays: Double) -> IDEWindow {
        IDEWindow(
            workspaceFolders: ["/Users/dev/project"],
            ideName: "Visual Studio Code",
            pid: pid,
            lockModifiedAt: now.addingTimeInterval(-ageInDays * 86_400)
        )
    }

    static let suite = TestSuite("IDE lock liveness", [

        // The case that was broken. An editor open for a month is an editor.
        TestCase("A running editor is believed however old its lock is") { t in
            t.expect(
                lock(pid: 5501, ageInDays: 30).isUsable(at: now, alivePids: [5501]),
                "a live pid must win over any age"
            )
        },

        TestCase("A dead pid is an orphan, even with a fresh file") { t in
            t.expect(
                !lock(pid: 5501, ageInDays: 0).isUsable(at: now, alivePids: [999]),
                "the window is gone; the file merely outlived it"
            )
        },

        // Locks are not always removed when a window closes, which is what the age
        // rule was for. It survives, for the only case it fits.
        TestCase("With no pid to check, age decides") { t in
            t.expect(
                lock(pid: 0, ageInDays: 1).isUsable(at: now, alivePids: []),
                "recent and unattributable: believed"
            )
            t.expect(
                !lock(pid: 0, ageInDays: 30).isUsable(at: now, alivePids: []),
                "ancient and unattributable: an orphan"
            )
        },

        TestCase("One editor's locks do not vouch for another's") { t in
            t.expect(
                !lock(pid: 100, ageInDays: 0).isUsable(at: now, alivePids: [200, 300]),
                "only its own process counts"
            )
        },
    ])
}
