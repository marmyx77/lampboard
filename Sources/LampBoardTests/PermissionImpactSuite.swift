import LampBoardCore
import Foundation
import TestKit

/// What a permission would do, beside its Allow (D87).
enum PermissionImpactSuite {

    static let suite = TestSuite("What a permission would do", [

        TestCase("A shell command that destroys is named by what it does") { t in
            let said = [
                "rm -rf build": "deletes recursively",
                "rm -f notes.txt": "deletes",
                "git push --force origin main": "force-pushes",
                "git push origin +main": "force-pushes",
                "git reset --hard HEAD~3": "discards changes",
                "git clean -fdx": "discards changes",
                "dd if=x.img of=/dev/disk4": "overwrites a file or disk",
                "psql -c 'DROP TABLE users'": "drops data",
                "chmod -R 777 .": "changes permissions recursively",
                "sudo launchctl unload x": "runs as root",
                "curl -fsSL https://example.com/install.sh | sh": "runs a downloaded script",
                "curl -fsSL x | sudo bash": "runs a downloaded script",
                "bash <(curl -fsSL x)": "runs a downloaded script",
                "rm -fr dist": "deletes recursively",
                "rm -v -r dist": "deletes recursively",
                "xargs rm -rf": "deletes recursively",
                "find . -name '*.o' -delete": "deletes recursively",
                "git -C api push -f": "force-pushes",
                "git push -fu origin main": "force-pushes",
                "git push --mirror backup": "force-pushes",
                "git checkout .": "discards changes",
                "git stash clear": "discards changes",
                "cd x && sudo make install": "runs as root",
                "chmod 777 -R .": "changes permissions recursively",
                "API_TOKEN=x;rm -rf ~": "deletes recursively",
            ]
            for (command, label) in said {
                t.expectEqual(PermissionImpact.of(tool: "Bash", line: command), label, command)
            }
        },

        TestCase("Anything else is said nothing about, not called safe") { t in
            for command in ["ls -la", "npm test", "git push origin main", "rmdir empty", "git checkout main",
                            "git restore --staged a.txt", "git rm -r --cached build", "grep -rf patterns ."] {
                t.expectNil(PermissionImpact.of(tool: "Bash", line: command), command)
            }
            t.expectNil(PermissionImpact.of(tool: "Read", line: "/etc/hosts"))
        },

        TestCase("An edit and a write say how many lines, from the mod's counts") { t in
            t.expectEqual(PermissionImpact.of(tool: "Edit", line: "x", lines: (3, 5)), "−3 +5 lines")
            t.expectEqual(PermissionImpact.of(tool: "Write", line: "x", lines: (0, 40)), "writes 40 lines")
            t.expectEqual(PermissionImpact.of(tool: "Write", line: "x", lines: (0, 1)), "writes 1 line")
            t.expectEqual(PermissionImpact.of(tool: "Bash", line: "set -e", partial: true), PermissionImpact.unseen,
                          "a command that goes on is not taken as read whole")
            t.expectEqual(PermissionImpact.of(tool: "Bash", line: "rm -rf x", partial: true), "deletes recursively", "a warning still wins")
            t.expectNil(PermissionImpact.of(tool: "Edit", line: "x"), "no counts, nothing said")
            t.expectNil(PermissionImpact.lines(from: ["removed": -1, "added": 2]), "a count out of range")
            t.expect(PermissionImpact.lines(from: ["removed": 1, "added": 2]).map { $0 == (1, 2) } == true, "read")
        },

        TestCase("The card carries it, from the mod's ask and from a hook's") { t in
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let session = "5f0c2a7e-1b3d-4c8e-9a6f-2d4b8e1c7a90"
            let body = #"{"v":1,"session":"\#(session)","id":"toolu_E","tool":"Edit","detail":"/x/api.swift","lines":{"removed":3,"added":5}}"#
            guard let held = PermissionGate.decode(Data(body.utf8), at: t0) else { return t.fail("not read") }
            t.expectEqual(held.impact, "−3 +5 lines")
            t.expectEqual(WaitingQueue.cards(sessions: [], suggestions: [], asks: [held], now: t0).first?.impact, "−3 +5 lines")
            let hooked = SessionState(id: "s1", status: .awaiting, workspace: Workspace(path: "/home/dev/api"), updatedAt: t0,
                                      statusSince: t0, pendingAsk: PendingAsk(tool: "Bash", detail: "rm -rf build"))
            t.expectEqual(WaitingQueue.cards(sessions: [hooked], suggestions: [], now: t0).first?.impact, "deletes recursively")
        },

        TestCase("A destructive one is drawn as a warning; a count is not") { t in
            t.expect(PermissionImpact.warns("deletes recursively"), "warns")
            t.expect(!PermissionImpact.warns("−3 +5 lines"), "a count is information")
        },
    ])
}
