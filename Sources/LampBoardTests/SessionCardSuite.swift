import LampBoardCore
import Foundation
import TestKit

/// A transcript becomes a small card: prompts, answer, files, failures, what got saved.
enum SessionCardSuite {

    typealias F = LampMasterFixtures

    static let suite = TestSuite("LampMaster: the session card", [

        TestCase("Prompts, the answer, the model and the context are read") { t in
            let card = F.card("s1", [
                F.prompt("rewrite the guide", at: 0),
                F.answer("Done: the guide is rewritten.", at: 1, context: 120_000),
            ])
            t.expectEqual(card.recentPrompts, ["rewrite the guide"])
            t.expectEqual(card.lastAnswer, "Done: the guide is rewritten.")
            t.expectEqual(card.model, "claude-opus-5-5")
            t.expectEqual(card.contextTokens, 120_000)
            t.expectEqual(card.cwd, "/home/dev/docs-site")
            t.expectEqual(card.lastActivity, F.at(1))
        },

        TestCase("Only the last three prompts are kept, clipped") { t in
            let long = String(repeating: "word ", count: 100)
            let card = F.card("s1", (0..<5).map { F.prompt("\($0) " + long, at: Double($0)) })
            t.expectEqual(card.recentPrompts.count, 3)
            t.expect(card.recentPrompts[0].hasPrefix("2 "), "the oldest kept is the third from last")
            t.expect(card.recentPrompts.allSatisfy { $0.count <= 220 }, "prompts clipped")
        },

        // The reader is handed whatever a file read returned: a record cut in two
        // must come out whole on the next call, not lost and not doubled.
        TestCase("A line cut between two chunks is read once, whole") { t in
            let text = F.prompt("split me", at: 0)
            var reader = SessionCardReader(sessionId: "s1")
            let cut = text.index(text.startIndex, offsetBy: 40)
            reader.consume(String(text[..<cut]))
            t.expectEqual(reader.card.recentPrompts, [])
            reader.consume(String(text[cut...]))
            t.expectEqual(reader.card.recentPrompts, ["split me"])
        },

        TestCase("Files written are counted, a read is not") { t in
            let card = F.card("s1", [
                F.call("a", tool: "Edit", input: ["file_path": "/home/dev/docs-site/src/a.ts"], at: 0),
                F.call("b", tool: "Write", input: ["file_path": "/home/dev/docs-site/src/b.ts"], at: 1),
                F.call("c", tool: "Edit", input: ["file_path": "/home/dev/docs-site/src/a.ts"], at: 2),
                F.call("d", tool: "Read", input: ["file_path": "/home/dev/docs-site/src/c.ts"], at: 3),
            ])
            t.expectEqual(card.filesWritten(since: F.at(0)),
                          ["/home/dev/docs-site/src/a.ts", "/home/dev/docs-site/src/b.ts"])
            t.expectEqual(card.filesWritten(since: F.at(1.5)), ["/home/dev/docs-site/src/a.ts"])
        },

        TestCase("A failed call is kept with its tool and fingerprint") { t in
            let card = F.card("s1", [
                F.call("a", tool: "Bash", input: ["command": "pnpm install"], at: 0),
                F.result("a", error: true, text: "ERR_PNPM_FETCH_404 at /Users/dev/x/package.json:12", at: 1),
            ])
            t.expectEqual(card.failures.count, 1)
            t.expectEqual(card.failures.first?.tool, "Bash")
            t.expectEqual(card.failures.first?.fingerprint, "err_pnpm_fetch_# at <path>:#")
        },

        TestCase("A successful commit, merge, push or pull request is a milestone") { t in
            let card = F.card("s1", [
                F.call("a", tool: "Bash", input: ["command": "git add -A && git commit -m 'merge the docs'"], at: 0),
                F.result("a", at: 1),
                F.call("b", tool: "Bash", input: ["command": "git -C repo push origin main"], at: 2),
                F.result("b", at: 3),
                F.call("c", tool: "Bash", input: ["command": "gh pr create --fill"], at: 4),
                F.result("c", at: 5),
            ])
            t.expectEqual(card.milestones.map(\.kind), [.commit, .push, .pullRequest])
        },

        TestCase("A failed commit is no milestone; a test run is one either way") { t in
            let card = F.card("s1", [
                F.call("a", tool: "Bash", input: ["command": "git commit -m x"], at: 0),
                F.result("a", error: true, text: "nothing to commit", at: 1),
                F.call("b", tool: "Bash", input: ["command": "swift test"], at: 2),
                F.result("b", error: true, text: "1 test failed", at: 3),
                F.call("c", tool: "Bash", input: ["command": "./Scripts/test.sh"], at: 4),
                F.result("c", at: 5),
            ])
            t.expectEqual(card.milestones.map(\.kind), [.testsFailed, .testsPassed])
        },

        TestCase("Work saved after the last prompt counts; before it, it does not") { t in
            let saved = F.card("s1", [
                F.prompt("ship it", at: 0),
                F.call("a", tool: "Bash", input: ["command": "git commit -m x"], at: 1),
                F.result("a", at: 2),
            ])
            t.expectEqual(saved.milestoneSinceLastPrompt?.kind, .commit)
            let asked = F.card("s1", [
                F.call("a", tool: "Bash", input: ["command": "git commit -m x"], at: 1),
                F.result("a", at: 2),
                F.prompt("now the next thing", at: 3),
            ])
            t.expectNil(asked.milestoneSinceLastPrompt)
        },

        TestCase("An answer that ends asking is told from one that ends telling") { t in
            t.expect(F.card("s", [F.answer("The build is ready. Shall I install it?", at: 0)]).lastAnswerAsks, "a question mark asks")
            t.expect(F.card("s", [F.answer("Ready. Let me know when you want it installed.", at: 0)]).lastAnswerAsks, "a request asks")
            t.expect(!F.card("s", [F.answer("Done: merged into main, all green.", at: 0)]).lastAnswerAsks, "a report does not ask")
        },

        TestCase("Sidechain records and the title record are handled apart") { t in
            let sidechain = F.line(["type": "user", "isSidechain": true, "timestamp": F.stamp(0),
                                    "origin": ["kind": "human"], "message": ["role": "user", "content": "agent"]])
            let title = F.line(["type": "ai-title", "aiTitle": "Guide rewrite"])
            let card = F.card("s", [sidechain, title])
            t.expectEqual(card.recentPrompts, [])
            t.expectEqual(card.title, "Guide rewrite")
        },
    ])
}
