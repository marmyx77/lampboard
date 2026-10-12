import Foundation
import LampBoardCore
import TestKit

/// The Hub (D149, hub-terminale) on an instance of its own, with its interface:
/// a session in tmux opens in its own terminal at the centre, attached once and
/// kept while chosen again; a session LampBoard has no terminal into is read from
/// its transcript; closing leaves the sessions running. The tmux is a fake that
/// writes down every attach.
enum HubE2ESuite {

    static let working = "d1e2f3a4-1111-4aaa-8bbb-000000000001"
    static let resting = "d1e2f3a4-2222-4aaa-8bbb-000000000002"

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        let app = AppUnderTest(binaryURL: binaryURL, port: port)
        app.headless = false
        var sleepers: [Process] = []
        let bin = app.home.appendingPathComponent(".local/bin")
        app.beforeLaunch = { _ in
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let tmux = """
            #!/bin/sh
            here="$(dirname "$0")"
            printf '%s\\n' "$*" >> "$here/tmux-calls.txt"
            [ "$1" = "-u" ] && shift
            case "$1" in
              list-panes) cat "$here/panes.txt" 2>/dev/null ;;
              attach-session) printf '\\033[?2004h'; stty raw -echo 2>/dev/null; exec dd bs=1 of="$here/typed.txt" 2>/dev/null ;;
              has-session) exit 1 ;;
              display-message) t="$4"; t="${t#=}"; printf '%s:0.0\\n' "${t%:}" ;;
            esac
            """
            try? tmux.write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("tmux").path)
        }
        /// Every call the Hub made to tmux, one a line.
        func tmuxCalls() -> String {
            (try? String(contentsOf: bin.appendingPathComponent("tmux-calls.txt"), encoding: .utf8)) ?? ""
        }
        /// How many times the Hub attached to the tmux session.
        func attaches() -> Int {
            let calls = (try? String(contentsOf: bin.appendingPathComponent("tmux-calls.txt"), encoding: .utf8)) ?? ""
            return calls.split(separator: "\n").filter { $0.hasPrefix("attach-session") }.count
        }
        let domain = "com.lampboard.app.test.\(app.home.lastPathComponent)"

        func transcript(_ id: String) -> URL { app.home.appendingPathComponent(".claude/projects/e2e/\(id).jsonl") }

        func ready() -> Bool {
            if app.isRunning { return true }
            let defaults = UserDefaults(suiteName: domain)
            defaults?.removePersistentDomain(forName: domain)
            defaults?.set(true, forKey: "terminal.sessions")
            defaults?.synchronize()
            guard (try? app.start()) != nil else { return false }
            try? FileManager.default.createDirectory(at: transcript(working).deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = [
                #"{"type":"user","uuid":"u1","sessionId":"\#(working)","timestamp":"2026-10-10T10:00:00.000Z","message":{"role":"user","content":"Move the token check into a middleware."}}"#,
                #"{"type":"assistant","uuid":"a1","sessionId":"\#(working)","timestamp":"2026-10-10T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Moved, and the auth tests pass."}]}}"#,
                #"{"type":"user","uuid":"u2","sessionId":"\#(working)","timestamp":"2026-10-10T10:01:00.000Z","message":{"role":"user","content":"Now the integration tests."}}"#,
            ]
            try? (lines.joined(separator: "\n") + "\n").write(to: transcript(working), atomically: true, encoding: .utf8)
            let quiet = #"{"type":"user","uuid":"r1","sessionId":"\#(resting)","timestamp":"2026-10-10T09:00:00.000Z","message":{"role":"user","content":"Update the pricing page."}}"#
            try? (quiet + "\n").write(to: transcript(resting), atomically: true, encoding: .utf8)
            makeProject(project)
            for (id, folder) in [(working, project), (resting, "/tmp/lbhub-e2e/site")] {
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let sleeper = Process()
                sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
                sleeper.arguments = ["900"]
                try? sleeper.run()
                sleepers.append(sleeper)
                app.writeLiveSession(sessionId: id, cwd: folder, entrypoint: "cli", pid: sleeper.processIdentifier)
                // The resting session sits in a tmux pane; the working one in no terminal LampBoard can reach.
                if id == resting {
                    try? "\(sleeper.processIdentifier)\tsite\t0\t0\n".write(to: bin.appendingPathComponent("panes.txt"), atomically: true, encoding: .utf8)
                }
                app.sendHook(HookPayloads.sessionStart(sessionId: id, cwd: folder)
                    .merging(["transcript_path": transcript(id).path]) { _, new in new }, entrypoint: "cli")
            }
            app.sendHook(HookPayloads.userPromptSubmit(sessionId: working, cwd: project)
                .merging(["transcript_path": transcript(working).path]) { _, new in new }, entrypoint: "cli")
            return wait(10) { (app.sessions()?.sessions.count ?? 0) >= 2 }
        }

        func files(_ wish: String) -> Int { app.raw(method: "POST", path: AppConfig.hubFilesPath, body: wish).status }

        func report() -> [String: Any] {
            let body = app.raw(method: "GET", path: AppConfig.hubPath).body
            return (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
        }

        func open(_ id: String) -> Int {
            app.raw(method: "POST", path: AppConfig.hubOpenPath, body: #"{"session":"\#(id)"}"#).status
        }

        func live() -> [[String: Any]] {
            let body = app.raw(method: "GET", path: AppConfig.livePath).body
            let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            return object?["views"] as? [[String: Any]] ?? []
        }

        return TestSuite("E2E · the Hub", [

            TestCase("a session LampBoard has no terminal into is read from its transcript at the centre") { a in
                guard ready() else { return a.fail("the instance did not come up with its two sessions") }
                a.expectEqual(open(working), 204)
                let read = wait(8) { (report()["readerMessages"] as? Int ?? 0) >= 3 }
                let shown = report()
                a.expect(read, "three messages read: \(shown)")
                a.expectEqual(shown["centre"] as? String, "reading")
                a.expectEqual(shown["open"] as? Bool, true)
                a.expectEqual(shown["selected"] as? String, working)
                a.expectEqual(shown["status"] as? String, SessionStatus.working.rawValue)
                a.expectEqual(shown["sessionsShown"] as? Bool, true, "the sessions' column is there")
                a.expectEqual(shown["guide"] as? Bool, true, "the first time, the guide")
                a.expectEqual(files(#"{"guide":false}"#), 204)
                a.expectEqual(report()["guide"] as? Bool, false, "read: it goes, and stays gone")
            },

            TestCase("a session in tmux opens in its own terminal at the centre, attached once and kept while chosen again") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(resting), 204)
                // The panes are learnt every ten seconds.
                a.expect(wait(14) { report()["centre"] as? String == "terminal" }, "the terminal: \(report())")
                a.expectEqual(report()["target"] as? String, "tmux::site:0.0")
                a.expect(wait(4) { attaches() == 1 }, "one attach: \(attaches())")
                a.expectEqual(live().first?["inHub"] as? Bool, true, "the terminal is the Hub's: \(live())")
                a.expectEqual(open(working), 204)
                a.expect(wait(4) { report()["centre"] as? String == "reading" }, "the other is read")
                a.expectEqual(open(resting), 204)
                a.expect(wait(4) { report()["centre"] as? String == "terminal" }, "back")
                Thread.sleep(forTimeInterval: 1)
                a.expectEqual(attaches(), 1, "back on it, the same attach")
            },

            TestCase("a file dropped on the terminal is typed as its escaped path, a cited one as @path, as one paste") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(resting), 204)
                a.expect(wait(14) { report()["centre"] as? String == "terminal" }, "the terminal")
                func typed() -> String {
                    (try? String(contentsOf: bin.appendingPathComponent("typed.txt"), encoding: .utf8)) ?? ""
                }
                a.expect(wait(6) { files(#"{"drop":{"files":["/tmp/lb drop/shot (1).png"]}}"#) == 204 && !typed().isEmpty }, "dropped")
                a.expect(wait(4) { typed().contains(#"/tmp/lb\ drop/shot\ \(1\).png "#) }, "the path, escaped as Terminal does: \(typed())")
                a.expect(typed().contains("\u{1b}[200~"), "as a paste, so nothing runs before Enter: \(typed().debugDescription)")
                a.expectEqual(files(#"{"drop":{"text":"@src/a.swift"}}"#), 204)
                a.expect(wait(4) { typed().contains("@src/a.swift") }, "a file from the tree, cited: \(typed())")
                a.expect(!typed().contains("\r"), "no Enter: the person sends it")
            },

            TestCase("out to a window of its own and back, the same attach; closing the Hub ends it") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(resting), 204)
                a.expect(wait(14) { report()["centre"] as? String == "terminal" }, "the terminal")
                let before = attaches()
                a.expectEqual(files(#"{"popOut":true}"#), 204)
                a.expect(wait(4) { report()["centre"] as? String == "inWindow" }, "in a window: \(report())")
                a.expectEqual(live().first?["inHub"] as? Bool, false, "a window holds it: \(live())")
                a.expectEqual(files(#"{"bringBack":true}"#), 204)
                a.expect(wait(4) { report()["centre"] as? String == "terminal" }, "back: \(report())")
                a.expectEqual(live().first?["inHub"] as? Bool, true)
                a.expectEqual(attaches(), before, "never a second attach")
                a.expectEqual(files(#"{"close":true}"#), 204)
                a.expect(wait(4) { live().isEmpty }, "closed, no terminal left: \(live())")
                a.expectEqual(open(resting), 204)
                a.expect(wait(6) { report()["centre"] as? String == "terminal" && live().count == 1 }, "opened again: \(live())")
                // The attach is a process: its fake writes its call a moment after it starts.
                a.expect(wait(4) { attaches() == before + 1 }, "a new attach after closing: \(attaches()) for \(before + 1)")
            },

            TestCase("a project attached, and a session started there in tmux under the id LampBoard chose, shown at once") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(files(#"{"addProject":{"path":"\#(project)"}}"#), 204)
                a.expect((report()["projects"] as? [String] ?? []).contains("+atlas-api"), "attached: \(report()["projects"] ?? "none")")
                a.expectEqual(files(#"{"start":{"folder":"\#(project)"}}"#), 204)
                a.expect(wait(8) { (report()["pending"] as? [String])?.count == 1 && report()["centre"] as? String == "terminal" },
                         "its terminal at once: \(report())")
                let id = (report()["pending"] as? [String])?.first ?? "none"
                a.expectEqual(report()["heading"] as? String, "atlas-api")
                let calls = tmuxCalls()
                a.expect(calls.contains("new-session -d -s atlas-api -c \(project) "), "a new tmux session in the project: \(calls)")
                a.expect(calls.contains("claude --session-id \(id)"), "under the id LampBoard chose: \(calls)")
                a.expect(calls.contains("set-option -t =atlas-api: status off"), "the status line off")
                a.expect(wait(4) { tmuxCalls().contains("attach-session -t =atlas-api:0.0") }, "attached: \(tmuxCalls())")
            },

            TestCase("a conversation a process holds is not taken up again: one writer") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(files(#"{"resume":{"id":"\#(working)","folder":"\#(project)"}}"#), 204)
                a.expect(wait(4) { (report()["failure"] as? String)?.contains("open on this Mac") == true }, "refused: \(report()["failure"] ?? "none")")
                a.expect(!tmuxCalls().contains("--resume \(working)"), "nothing started")
            },

            TestCase("the project's tree and what git says of each file are beside the conversation") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(working), 204)
                a.expectEqual(files(#"{"files":true}"#), 204)
                a.expect(wait(6) { (report()["treeEntries"] as? [String] ?? []).contains("src/") }, "the tree: \(report()["treeEntries"] ?? "none")")
                let shown = report()
                a.expectEqual(shown["filesShown"] as? Bool, true)
                a.expectEqual(shown["projectRoot"] as? String, project)
                a.expect(wait(6) { (report()["git"] as? [String: String])?["src/a.swift"] == "M" }, "git: \(report()["git"] ?? "none")")
                a.expectEqual((report()["git"] as? [String: String])?["notes.txt"], "?")
            },

            TestCase("a Markdown file opens as a preview, and as code on asking") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(files(#"{"open":"README.md"}"#), 204)
                a.expect(wait(5) { (report()["openFileText"] as? String)?.contains("# Atlas") == true }, "\(report()["openFileText"] ?? "none")")
                a.expectEqual(report()["lastShown"] as? Bool, true, "opening a file shows the last column")
                a.expectEqual(report()["openFilePreview"] as? Bool, true)
                a.expectEqual(files(#"{"preview":false}"#), 204)
                a.expectEqual(report()["openFilePreview"] as? Bool, false)
            },

            TestCase("a README of 100 KB and a one-line file of 300 KB are drawn in their column, and the main thread stays free") { a in
                guard ready() else { return a.fail("no instance") }
                // 10 October 2026: a README held the main thread for tens of
                // seconds, then code showed numbers without text, then wrapped
                // text ran past the column. Each is a number here.
                let part = "## Part\n\nWords of a long document that goes on and on. **Bold** and `code`.\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n"
                try? String(repeating: part, count: 800).write(toFile: project + "/BIG.md", atomically: true, encoding: .utf8)
                try? ("[" + (0..<30_000).map { "{\"k\":\($0)}" }.joined(separator: ",") + "]").write(toFile: project + "/wide.json", atomically: true, encoding: .utf8)
                func drawn() -> [String: Any] { report()["viewer"] as? [String: Any] ?? [:] }
                func length(_ name: String) -> Int {
                    ((try? String(contentsOfFile: project + "/" + name, encoding: .utf8)) ?? "").utf16.count
                }
                // The file's own text in sight: the view of the file before stays
                // until this one is made, and would answer for it.
                func check(_ what: String, wraps: Bool, numbered: Bool, chars: Int? = nil) {
                    a.expect(wait(20) {
                        (drawn()["glyphsInSight"] as? Int ?? 0) > 0 && (chars == nil || drawn()["chars"] as? Int == chars)
                    }, "\(what): text in sight: \(drawn())")
                    let view = drawn()
                    a.expectEqual(view["inWindow"] as? Bool, true, "\(what): inside the window")
                    a.expectEqual(view["wraps"] as? Bool, wraps, "\(what): wrapping")
                    if wraps { a.expectEqual(view["textWidth"] as? Int, view["columnWidth"] as? Int, "\(what): as wide as its column") }
                    a.expect((((view["margin"] as? Int) ?? 0) > 20) == numbered, "\(what): the numbers' margin: \(view)")
                    a.expect((report()["mainLongestMs"] as? Int ?? 9999) < 500, "\(what): main thread held \(report()["mainLongestMs"] ?? "?") ms")
                }
                a.expectEqual(files(#"{"resetWatch":true}"#), 204)
                a.expectEqual(files(#"{"open":"BIG.md"}"#), 204)
                check("BIG.md as preview", wraps: true, numbered: false)
                a.expectEqual(files(#"{"preview":false}"#), 204)
                check("BIG.md as code", wraps: false, numbered: true, chars: length("BIG.md"))
                a.expectEqual(files(#"{"open":"wide.json"}"#), 204)
                check("one line of 300 KB", wraps: true, numbered: true, chars: length("wide.json"))
            },

            TestCase("closed and opened again on the same session, the Hub reads its conversation and asks git again") { a in
                guard ready() else { return a.fail("no instance") }
                // A review finding: the same session chosen again changed
                // nothing, so the conversation stayed empty and git unasked.
                a.expectEqual(files(#"{"close":true}"#), 204)
                a.expect(wait(4) { report()["open"] as? Bool == false }, "closed")
                try? "new\n".write(toFile: project + "/reopened.txt", atomically: true, encoding: .utf8)
                a.expectEqual(open(working), 204)
                a.expect(wait(6) { (report()["readerMessages"] as? Int ?? 0) > 0 }, "the conversation: \(report()["readerMessages"] ?? "none")")
                a.expect(wait(8) { (report()["git"] as? [String: String])?["reopened.txt"] == "?" }, "git asked again: \(report()["git"] ?? "none")")
                try? FileManager.default.removeItem(atPath: project + "/reopened.txt")
            },

            TestCase("a file through a link out of the project is not read") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(files(#"{"open":"out/hosts"}"#), 204)
                _ = wait(2) { report()["openFile"] as? String == "out/hosts" }
                let text = report()["openFileText"] as? String ?? ""
                a.expect(!text.contains("localhost"), "/etc/hosts must not be read: \(text.prefix(80))")
            },

            TestCase("a search finds the line, and the session's tools colour the files they touched") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(files(#"{"query":"let answer"}"#), 204)
                a.expect(wait(5) { (report()["searchHits"] as? [String] ?? []).contains("src/a.swift:1") }, "\(report()["searchHits"] ?? "none")")
                let tool = #"{"v":1,"kind":"tool","session":"\#(working)","id":"toolu_e2e_edit_1","tool":"Edit","detail":"\#(project)/src/a.swift","phase":"start"}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: tool).status, 204)
                a.expect(wait(6) { (report()["marks"] as? [String: String])?["src/a.swift"] == "written" }, "\(report()["marks"] ?? "none")")
                a.expectEqual(files(#"{"query":""}"#), 204)
            },

            TestCase("the terminal is a shell in the project's folder") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(files(#"{"last":"terminal"}"#), 204)
                a.expect(wait(4) { report()["shellRunning"] as? Bool == true }, "\(report())")
                a.expectEqual(report()["lastColumn"] as? String, "terminal")
            },

            TestCase("closing the instance leaves nothing behind") { a in
                app.stop()
                sleepers.forEach { $0.terminate() }
                UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
                a.expect(!app.isRunning, "stopped")
            },
        ])
    }

    static let project = "/tmp/lbhub-e2e/atlas-api"

    /// A project with git, a change, a new file, a Markdown file and a link out.
    private static func makeProject(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try? "let answer = 41\n".write(toFile: root + "/src/a.swift", atomically: true, encoding: .utf8)
        try? "# Atlas\n\nThe example API.\n".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(atPath: root + "/out", withDestinationPath: "/etc")
        for args in [["init", "-q"], ["add", "src", "README.md"],
                     ["-c", "user.name=e2e", "-c", "user.email=e2e@example.com", "commit", "-q", "-m", "start"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", root] + args
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try? git.run()
            git.waitUntilExit()
        }
        try? "let answer = 42\n".write(toFile: root + "/src/a.swift", atomically: true, encoding: .utf8)
        try? "a new file\n".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
    }

    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
