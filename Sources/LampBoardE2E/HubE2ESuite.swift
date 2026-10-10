import CryptoKit
import Foundation
import LampBoardCore
import TestKit

/// The Hub (D149–D154) on an instance of its own, with its interface: it opens
/// on a session and reads its conversation; it writes only where it knows a way
/// in, and through the mod a message goes signed, as the person, in the mode the
/// composer is set to.
enum HubE2ESuite {

    static let working = "d1e2f3a4-1111-4aaa-8bbb-000000000001"
    static let resting = "d1e2f3a4-2222-4aaa-8bbb-000000000002"

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        let app = AppUnderTest(binaryURL: binaryURL, port: port)
        app.headless = false
        var sleepers: [Process] = []
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

        func open(_ id: String, mode: String? = nil) -> Int {
            let body = mode.map { #"{"session":"\#(id)","mode":"\#($0)"}"# } ?? #"{"session":"\#(id)"}"#
            return app.raw(method: "POST", path: AppConfig.hubOpenPath, body: body).status
        }

        func compose(_ text: String) -> Int {
            app.raw(method: "POST", path: AppConfig.hubComposePath, body: #"{"text":"\#(text)"}"#).status
        }

        func inbox(_ id: String) -> [CommandEnvelope] {
            let body = app.raw(method: "GET", path: AppConfig.modInboxPath, headers: ["X-LampBoard-Session": id]).body
            return (try? JSONDecoder().decode([CommandEnvelope].self, from: Data(body.utf8))) ?? []
        }

        func publicKey() -> Curve25519.Signing.PublicKey? {
            guard let text = try? String(contentsOf: app.home.appendingPathComponent(".lampboard/panel-key.pub"), encoding: .utf8),
                  let raw = CommandEnvelope.bytes(fromHex: text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }

        return TestSuite("E2E · the Hub", [

            TestCase("the Hub opens on a session and reads its conversation from the transcript") { a in
                guard ready() else { return a.fail("the instance did not come up with its two sessions") }
                a.expectEqual(open(working), 204)
                let read = wait(8) { (report()["chatMessages"] as? Int ?? 0) >= 3 }
                let shown = report()
                a.expect(read, "three messages read: \(shown)")
                a.expectEqual(shown["open"] as? Bool, true)
                a.expectEqual(shown["selected"] as? String, working)
                a.expectEqual(shown["status"] as? String, SessionStatus.working.rawValue)
                a.expectEqual(shown["sessionsShown"] as? Bool, true, "the sessions' column is there")
            },

            TestCase("a session that says nothing of commands is read only: nothing is sent, and the Hub says why") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(resting), 204)
                a.expectEqual(report()["route"] as? String, HubWrite.Route.none.rawValue)
                a.expectEqual(compose("hello"), 409)
                a.expect((report()["notice"] as? String)?.contains("Open its window") == true, "\(report())")
                a.expect(inbox(resting).isEmpty, "nothing queued")
            },

            TestCase("through the mod a message goes signed, as the person, and once") { a in
                guard ready() else { return a.fail("no instance") }
                let start = #"{"v":1,"kind":"start","session":"\#(working)","surface":"terminal","interactive":true,"features":["ask","commands"]}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: start).status, 204)
                a.expectEqual(open(working, mode: "queue"), 204)
                a.expect(wait(4) { report()["route"] as? String == HubWrite.Route.mod.rawValue }, "the route is the mod: \(report())")
                a.expectEqual(compose("Run the integration tests."), 204)
                let queued = inbox(working)
                guard let key = publicKey() else { return a.fail("no key") }
                let ops = queued.compactMap { try? CommandEnvelope.open($0, publicKey: key, session: working).get() }
                a.expect(ops.contains { $0.op == "stream" && $0.args["on"] == "true" }, "opening it follows its reply: \(ops.map(\.op))")
                guard let submit = queued.first(where: { (try? CommandEnvelope.open($0, publicKey: key, session: working).get().op) == "submit" })
                else { return a.fail("one message waits: \(ops.map(\.op))") }
                switch CommandEnvelope.open(submit, publicKey: key, session: working) {
                case .success(let payload):
                    a.expectEqual(payload.op, "submit")
                    a.expectEqual(payload.args["text"], "Run the integration tests.")
                    a.expectEqual(payload.args["asUser"], "true", "as the person's own words")
                    a.expectEqual(payload.args["mode"], "queue")
                case .failure(let refusal):
                    a.fail("the mod would refuse it: \(refusal)")
                }
                a.expect(inbox(working).isEmpty, "collected once")
            },

            TestCase("Interrupt tells the mod to stop the turn before the message") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(working, mode: "interrupt"), 204)
                a.expectEqual(report()["mode"] as? String, "interrupt")
                a.expectEqual(compose("Stop and look at this."), 204)
                let queued = inbox(working)
                guard let key = publicKey(),
                      let payload = queued.compactMap({ try? CommandEnvelope.open($0, publicKey: key, session: working).get() })
                          .first(where: { $0.op == "submit" })
                else { return a.fail("no message opened: \(queued.count)") }
                a.expectEqual(payload.args["mode"], "interrupt")
            },

            TestCase("the open session's reply arrives as it is written; another session's is dropped") { a in
                guard ready() else { return a.fail("no instance") }
                a.expectEqual(open(working), 204)
                a.expectEqual(report()["followed"] as? String, working, "the open session is followed")
                func stream(_ id: String, _ turn: String, _ text: String) -> Int {
                    app.raw(method: "POST", path: AppConfig.modStreamPath,
                            body: #"{"v":1,"session":"\#(id)","turnId":"\#(turn)","text":"\#(text)"}"#).status
                }
                a.expectEqual(stream(working, "turn-1", "Running the"), 204)
                a.expectEqual(stream(working, "turn-1", " tests"), 204)
                a.expectEqual(stream(resting, "turn-9", "not this one"), 204)
                a.expect(wait(2) { report()["liveText"] as? String == "Running the tests" }, "\(report()["liveText"] ?? "none")")
                a.expectEqual(stream(working, "turn-2", "A new turn"), 204)
                a.expect(wait(2) { report()["liveText"] as? String == "A new turn" }, "a new turn starts afresh")
            },

            TestCase("Stop goes to the mod as an abort, and the Hub says what keeps running") { a in
                guard ready() else { return a.fail("no instance") }
                _ = inbox(working)
                a.expectEqual(files(#"{"stop":true}"#), 204)
                guard let key = publicKey() else { return a.fail("no key") }
                let ops = inbox(working).compactMap { try? CommandEnvelope.open($0, publicKey: key, session: working).get().op }
                a.expectEqual(ops, ["abort"])
                a.expect((report()["notice"] as? String)?.contains("background") == true, "\(report()["notice"] ?? "none")")
            },

            TestCase("once the turn has ended the transcript has the reply, and the provisional text goes") { a in
                guard ready() else { return a.fail("no instance") }
                app.sendHook(HookPayloads.stop(sessionId: working, cwd: project)
                    .merging(["transcript_path": transcript(working).path]) { _, new in new }, entrypoint: "cli")
                a.expect(wait(4) { report()["liveText"] is NSNull }, "\(report()["liveText"] ?? "none")")
            },

            TestCase("a turn the person stopped rests the lamp, and an API error turns it red (E18, D160)") { a in
                guard ready() else { return a.fail("no instance") }
                func status() -> String? { report()["status"] as? String }
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: working, cwd: project), entrypoint: "cli")
                a.expect(wait(3) { status() == "working" }, "working: \(status() ?? "none")")
                let at = Int(Date().timeIntervalSince1970 * 1000)
                let stopped = #"{"v":1,"kind":"stopped","session":"\#(working)","turnId":"turn-5","at":\#(at)}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: stopped).status, 204)
                a.expect(wait(3) { status() == "idle" }, "a stop rests, not red: \(status() ?? "none")")
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: working, cwd: project), entrypoint: "cli")
                a.expect(wait(3) { status() == "working" }, "working again: \(status() ?? "none")")
                app.sendHook(HookPayloads.stopFailure(sessionId: working, cwd: project, errorType: "server_error"), entrypoint: "cli")
                a.expect(wait(3) { status() == "failed" }, "an error is red: \(status() ?? "none")")
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
