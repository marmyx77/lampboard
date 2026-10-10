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
            for (id, folder) in [(working, "/tmp/lbhub-e2e/atlas-api"), (resting, "/tmp/lbhub-e2e/site")] {
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
            app.sendHook(HookPayloads.userPromptSubmit(sessionId: working, cwd: "/tmp/lbhub-e2e/atlas-api")
                .merging(["transcript_path": transcript(working).path]) { _, new in new }, entrypoint: "cli")
            return wait(10) { (app.sessions()?.sessions.count ?? 0) >= 2 }
        }

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
                guard queued.count == 1, let key = publicKey() else { return a.fail("one command waits: \(queued.count)") }
                switch CommandEnvelope.open(queued[0], publicKey: key, session: working) {
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
                guard let first = queued.first, let key = publicKey(),
                      case .success(let payload) = CommandEnvelope.open(first, publicKey: key, session: working)
                else { return a.fail("no command opened: \(queued.count)") }
                a.expectEqual(payload.args["mode"], "interrupt")
            },

            TestCase("closing the instance leaves nothing behind") { a in
                app.stop()
                sleepers.forEach { $0.terminate() }
                UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
                a.expect(!app.isRunning, "stopped")
            },
        ])
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
