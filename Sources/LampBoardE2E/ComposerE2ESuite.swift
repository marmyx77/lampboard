import CryptoKit
import Foundation
import LampBoardCore
import TestKit

/// The Hub's command bar (D157) on an instance of its own: a file dropped into
/// the text goes as `@path` where it fell, a slash line the session knows goes
/// as a command, a model change over a warm cache asks twice, a mode is
/// reached and confirmed by the footer, an attachment lands in the project.
enum ComposerE2ESuite {

    static let session = "c0ffee00-1111-4aaa-8bbb-000000000001"
    static let project = "/tmp/lbcomposer-e2e/atlas"

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        let app = AppUnderTest(binaryURL: binaryURL, port: port)
        app.headless = false
        var sleepers: [Process] = []
        let domain = "com.lampboard.app.test.\(app.home.lastPathComponent)"
        let transcript = app.home.appendingPathComponent(".claude/projects/e2e/\(session).jsonl")

        func ready() -> Bool {
            if app.isRunning { return true }
            let defaults = UserDefaults(suiteName: domain)
            defaults?.removePersistentDomain(forName: domain)
            defaults?.set(true, forKey: "terminal.sessions")
            defaults?.synchronize()
            guard (try? app.start()) != nil else { return false }
            makeProject()
            try? FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A reply that wrote the cache a moment ago, for an hour: the cache is warm.
            let now = ISO8601DateFormatter().string(from: Date())
            let lines = [
                #"{"type":"user","uuid":"u1","sessionId":"\#(session)","timestamp":"\#(now)","message":{"role":"user","content":"Read the API."}}"#,
                #"{"type":"assistant","uuid":"a1","sessionId":"\#(session)","timestamp":"\#(now)","message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Read."}],"usage":{"input_tokens":12,"cache_creation_input_tokens":40000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":40000,"ephemeral_5m_input_tokens":0},"output_tokens":3}}}"#,
            ]
            try? (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["900"]
            try? sleeper.run()
            sleepers.append(sleeper)
            app.writeLiveSession(sessionId: session, cwd: project, entrypoint: "cli", pid: sleeper.processIdentifier)
            app.sendHook(HookPayloads.sessionStart(sessionId: session, cwd: project)
                .merging(["transcript_path": transcript.path]) { _, new in new }, entrypoint: "cli")
            app.sendHook(HookPayloads.stop(sessionId: session, cwd: project)
                .merging(["transcript_path": transcript.path]) { _, new in new }, entrypoint: "cli")
            guard wait(10, until: { (app.sessions()?.sessions.count ?? 0) >= 1 }) else { return false }
            let start = #"{"v":1,"kind":"start","session":"\#(session)","surface":"terminal","interactive":true,"features":["ask","commands"]}"#
            _ = mod(start)
            Thread.sleep(forTimeInterval: 0.5)
            guard open() == 204 else { return false }
            let commands = #"{"v":1,"kind":"commands","session":"\#(session)","list":[{"name":"compact","description":"Keep a summary"},{"name":"plan","description":"Enable plan mode"},{"name":"remote-control","description":"Continue on the phone"}]}"#
            _ = mod(commands)
            app.sendHook(HookPayloads.userPromptSubmit(sessionId: session, cwd: project)
                .merging(["transcript_path": transcript.path, "permission_mode": "auto"]) { _, new in new }, entrypoint: "cli")
            app.sendHook(HookPayloads.stop(sessionId: session, cwd: project)
                .merging(["transcript_path": transcript.path]) { _, new in new }, entrypoint: "cli")
            return wait(5) { (report()["commands"] as? [String])?.count == 3 && report()["sessionMode"] as? String == "auto" }
        }

        func mod(_ body: String) -> Int { app.raw(method: "POST", path: AppConfig.modPath, body: body).status }
        func open() -> Int { app.raw(method: "POST", path: AppConfig.hubOpenPath, body: #"{"session":"\#(session)","mode":"queue"}"#).status }
        func wish(_ body: String) -> Int { app.raw(method: "POST", path: AppConfig.hubFilesPath, body: body).status }
        func send() -> Int { app.raw(method: "POST", path: AppConfig.hubComposePath, body: #"{"text":"\#(composerText())","confirm":true}"#).status }
        func composerText() -> String {
            (report()["composerText"] as? String ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        }

        func report() -> [String: Any] {
            let body = app.raw(method: "GET", path: AppConfig.hubPath).body
            return (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
        }

        func queued() -> [CommandEnvelope.Payload] {
            guard let text = try? String(contentsOf: app.home.appendingPathComponent(".lampboard/panel-key.pub"), encoding: .utf8),
                  let raw = CommandEnvelope.bytes(fromHex: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { return [] }
            let body = app.raw(method: "GET", path: AppConfig.modInboxPath, headers: ["X-LampBoard-Session": session]).body
            let envelopes = (try? JSONDecoder().decode([CommandEnvelope].self, from: Data(body.utf8))) ?? []
            return envelopes.compactMap { try? CommandEnvelope.open($0, publicKey: key, session: session).get() }
        }

        return TestSuite("E2E · the Hub's command bar", [

            TestCase("a file dropped into the text goes as @path where it fell, and is sent so (E23)") { a in
                guard ready() else { return a.fail("no instance") }
                _ = queued()
                a.expectEqual(wish(#"{"composer":"Fix this please"}"#), 204)
                a.expectEqual(wish(#"{"drop":"@src/a.swift","at":8}"#), 204)
                a.expect(wait(2) { report()["composerText"] as? String == "Fix this @src/a.swift please" }, "\(report()["composerText"] ?? "none")")
                a.expectEqual(send(), 204)
                a.expectEqual(queued().filter { $0.op == "submit" }.map { $0.args["text"] }, ["Fix this @src/a.swift please"])
            },

            TestCase("a slash line the session knows goes as its command, not as words for the model (E24)") { a in
                guard ready() else { return a.fail("no instance") }
                _ = queued()
                a.expectEqual(wish(#"{"composer":"/compact keep the API notes"}"#), 204)
                a.expectEqual(send(), 204)
                let ops = queued()
                a.expectEqual(ops.map(\.op), ["command"])
                a.expectEqual(ops.first?.args["name"], "compact")
                a.expectEqual(ops.first?.args["args"], "keep the API notes")
                a.expectEqual(report()["composerText"] as? String, "", "the box empties")
                a.expectEqual(wish(#"{"composer":"/etc/hosts has a typo"}"#), 204)
                a.expectEqual(send(), 204)
                a.expectEqual(queued().map(\.op), ["submit"], "a path is words")
            },

            TestCase("a model chosen over a warm cache asks first, then goes for this session alone (E25)") { a in
                guard ready() else { return a.fail("no instance") }
                a.expect(wait(5) { report()["cacheWarm"] as? Bool == true }, "the transcript's cache is warm")
                _ = queued()
                a.expectEqual(wish(#"{"model":"claude-haiku-5-5"}"#), 204)
                a.expect((report()["barWarning"] as? String)?.contains("cache is warm") == true, "\(report()["barWarning"] ?? "none")")
                a.expect(queued().isEmpty, "nothing changed yet")
                a.expectEqual(wish(#"{"model":"claude-haiku-5-5"}"#), 204)
                let ops = queued()
                a.expectEqual(ops.map(\.op), ["model"])
                a.expectEqual(ops.first?.args["value"], "claude-haiku-5-5")
                a.expectEqual(report()["chosenModel"] as? String, "claude-haiku-5-5")
                a.expectEqual(wish(#"{"effort":"low"}"#), 204)
                a.expectEqual(queued().first?.args["value"], "low")
                a.expectEqual(report()["chosenEffort"] as? String, "low")
            },

            TestCase("Plan is reached by its command, held until the hooks say otherwise; nothing is pressed while the session asks (E26)") { a in
                guard ready() else { return a.fail("no instance") }
                _ = queued()
                a.expectEqual(wish(#"{"mode":"plan"}"#), 204)
                a.expectEqual(report()["reaching"] as? String, "plan")
                let ops = queued()
                a.expectEqual(ops.first?.op, "command")
                a.expectEqual(ops.first?.args["name"], "plan")
                a.expect(report()["sessionMode"] as? String == "auto", "the hooks still say auto")
                a.expectEqual(mod(#"{"v":1,"kind":"done","session":"\#(session)","nonce":"cd34","op":"command","ok":true}"#), 204)
                a.expect(wait(3) { report()["sessionMode"] as? String == "plan" && report()["reaching"] is NSNull }, "\(report())")
                Thread.sleep(forTimeInterval: 1.5)
                a.expectEqual(report()["sessionMode"] as? String, "plan", "held while the hooks still give the old word")
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: session, cwd: project)
                    .merging(["transcript_path": transcript.path, "permission_mode": "auto"]) { _, new in new }, entrypoint: "cli")
                a.expect(wait(3) { report()["sessionMode"] as? String == "auto" }, "a newer word wins: \(report()["sessionMode"] ?? "none")")
                app.sendHook(HookPayloads.notification(sessionId: session, cwd: project, kind: "permission_prompt")
                    .merging(["message": "Claude needs your permission to use Bash"]) { _, new in new }, entrypoint: "cli")
                a.expect(wait(3) { report()["status"] as? String == SessionStatus.awaiting.rawValue }, "asking again")
                a.expectEqual(wish(#"{"mode":"plan"}"#), 204)
                a.expect(report()["reaching"] is NSNull, "never over a dialog")
                a.expect(queued().isEmpty, "nothing sent")
                app.sendHook(HookPayloads.stop(sessionId: session, cwd: project)
                    .merging(["transcript_path": transcript.path]) { _, new in new }, entrypoint: "cli")
            },

            TestCase("Remote Control is the session's own command, and the bar says when it is on") { a in
                guard ready() else { return a.fail("no instance") }
                _ = queued()
                a.expectEqual(wish(#"{"remote":true}"#), 204)
                a.expectEqual(queued().first?.args["name"], "remote-control")
                a.expectEqual(mod(#"{"v":1,"kind":"surfaces","session":"\#(session)","list":["terminal","mobile"]}"#), 204)
                a.expect(wait(3) { report()["remote"] as? Bool == true }, "on")
            },

            TestCase("an attachment lands in the project's folder for them, out of git, and is cited (E27)") { a in
                guard ready() else { return a.fail("no instance") }
                let picture = FileManager.default.temporaryDirectory.appendingPathComponent("lb e2e shot.png")
                try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
                defer { try? FileManager.default.removeItem(at: picture) }
                a.expectEqual(wish(#"{"composer":"Look at"}"#), 204)
                a.expectEqual(wish(#"{"attach":["\#(picture.path)"]}"#), 204)
                a.expect(wait(4) { (report()["composerText"] as? String)?.contains("@.lampboard/allegati/lb-e2e-shot.png") == true },
                         "\(report()["composerText"] ?? "none")")
                a.expectEqual(try? Data(contentsOf: URL(fileURLWithPath: project + "/.lampboard/allegati/lb-e2e-shot.png")),
                              Data([0x89, 0x50, 0x4E, 0x47]))
                let exclude = (try? String(contentsOfFile: project + "/.git/info/exclude", encoding: .utf8)) ?? ""
                a.expect(exclude.contains(".lampboard/"), "kept out of git")
            },

            TestCase("closing the instance leaves nothing behind") { a in
                app.stop()
                sleepers.forEach { $0.terminate() }
                UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
                try? FileManager.default.removeItem(atPath: "/tmp/lbcomposer-e2e")
                a.expect(!app.isRunning, "stopped")
            },
        ])
    }

    private static func makeProject() {
        try? FileManager.default.removeItem(atPath: project)
        try? FileManager.default.createDirectory(atPath: project + "/src", withIntermediateDirectories: true)
        try? "let answer = 42\n".write(toFile: project + "/src/a.swift", atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", project, "init", "-q"]
        try? git.run()
        git.waitUntilExit()
    }

    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
}
