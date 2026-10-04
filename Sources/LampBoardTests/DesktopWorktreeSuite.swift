import LampBoardCore
import Foundation
import TestKit

/// The Claude application's worktree rows are named after their project.
enum DesktopWorktreeSuite {

    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(
        folder: String, git: GitIdentity?, entrypoint: String? = ClaudeDesktop.hookEntrypoint
    ) -> SessionState {
        SessionState(
            id: "s", status: .idle,
            workspace: Workspace(path: "/home/dev/Exit/.claude/worktrees/" + folder, host: "node"),
            updatedAt: at, statusSince: at, git: git, entrypoint: entrypoint
        )
    }

    private static let worktree = GitIdentity(
        repo: "Ledger", branch: "claude/vigilant-ramanujan-790712", isWorktree: true
    )

    static let suite = TestSuite("Rows of the Claude application's worktrees", [

        TestCase("A worktree row reads as its project and the worktree, without the serial") { t in
            t.expectEqual(session(folder: "vigilant-ramanujan-790712", git: worktree).displayName,
                          "Ledger · vigilant-ramanujan")
        },

        TestCase("Both spellings of the application are recognised") { t in
            t.expectEqual(
                session(folder: "vigilant-ramanujan-790712", git: worktree, entrypoint: ClaudeDesktop.entrypoint).displayName,
                "Ledger · vigilant-ramanujan"
            )
        },

        // An editor row's name is the title of the window it raises: it must not
        // change, or the row stops agreeing with its window.
        TestCase("An editor's worktree row keeps its folder's name") { t in
            t.expectEqual(
                session(folder: "vigilant-ramanujan-790712", git: worktree, entrypoint: "claude-vscode").displayName,
                "vigilant-ramanujan-790712"
            )
        },

        TestCase("A row that is not in a worktree keeps its folder's name") { t in
            let plain = GitIdentity(repo: "Ledger", branch: "main", isWorktree: false)
            t.expectEqual(session(folder: "Ledger", git: plain).displayName, "Ledger")
        },

        TestCase("A worktree whose folder is the repository's name adds nothing") { t in
            let same = GitIdentity(repo: "Ledger", branch: "x", isWorktree: true)
            t.expectNil(DesktopWorktree.label(folder: "Ledger", git: same))
        },

        TestCase("Only a numeric tail is trimmed") { t in
            t.expectEqual(DesktopWorktree.label(folder: "fix-login", git: worktree), "Ledger · fix-login")
            t.expectEqual(DesktopWorktree.label(folder: "790712", git: worktree), "Ledger · 790712")
            t.expectEqual(DesktopWorktree.label(folder: "calm-hopper-12", git: worktree), "Ledger · calm-hopper")
        },

        // A name the person gave still wins over this one.
        TestCase("A name given to the row still wins") { t in
            let s = session(folder: "vigilant-ramanujan-790712", git: worktree)
            let row = ColumnLayout.render(
                TrafficLightState(sessions: ["s": s]),
                options: ColumnOptions(names: [s.workspace.key: "Lifegate"])
            ).rows.first
            t.expectEqual(row?.displayName, "Lifegate")
        },
    ])
}
