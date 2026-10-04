import LampBoardCore
import Foundation
import TestKit

/// The companion mod's route in the real binary: the port it reads, the token
/// it must carry, and a measure that lands on a row the hooks announced.
///
/// The bodies are the ones `mod/hooks/register.js` writes; the mod itself is
/// run against a real Claude Code on the test Mac, outside this suite.
enum ModE2ESuite {

    static let sessionId = "e2e0d0d0-0000-4000-8000-0000000000aa"
    static let stranger = "e2e0d0d0-0000-4000-8000-0000000000bb"

    static func measure(_ id: String, tokens: Int) -> String {
        #"{"v":1,"kind":"measure","session":"\#(id)","model":"claude-opus-5-5","#
            + #""context":{"tokens":\#(tokens),"window":200000},"#
            + #""rateLimits":[{"kind":"five_hour","percentUsed":20,"resetsAt":"2026-10-04T09:30:00.000Z"}],"#
            + #""cost":{"usd":0.0968}}"#
    }

    /// - Parameter port: for an instance of its own, whose home nothing else
    ///   starts on: the shared one is restarted on other ports by other suites,
    ///   and each launch rightly rewrites the port.
    static func suite(_ app: AppUnderTest, binaryURL: URL, port: UInt16) -> TestSuite {
        TestSuite("E2E · companion mod", [

            TestCase("the port is written for the mod, readable by the user only") { a in
                let own = AppUnderTest(binaryURL: binaryURL, port: port)
                defer { own.stop() }
                do { try own.start() } catch { return a.fail("instance did not start: \(error)") }
                let url = own.home.appendingPathComponent(".lampboard/port")
                let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                a.expectEqual(text, String(port))
                let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
                a.expectEqual(mode?.int16Value, 0o600)
            },

            TestCase("/mod refuses a missing or wrong token, and a body that is not a report") { a in
                let body = measure(sessionId, tokens: 1)
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, token: .some(nil), body: body).status, 401)
                let wrong = String(repeating: "b", count: AccessToken.byteCount * 2)
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, token: .some(wrong), body: body).status, 401)
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: "{\"v\":1}").status, 400)
                a.expectEqual(app.raw(method: "GET", path: AppConfig.modPath).status, 405)
            },

            TestCase("a measure lands on the row as the session's own count") { a in
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: sessionId, cwd: LifecycleSuite.workspace))
                guard app.waitUntil({ app.status(of: sessionId) == "working" }) else {
                    return a.fail("the hook made no row: \(app.status(of: sessionId))")
                }
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: measure(sessionId, tokens: 47_162)).status, 204)
                // The receiver hops to the main actor: give it a moment.
                a.expect(app.waitUntil { app.session(id: sessionId)?.contextConfidence == "reported" },
                         "confidence: \(app.session(id: sessionId)?.contextConfidence ?? "none")")
                let row = app.session(id: sessionId)
                a.expectEqual(row?.contextTokens, 47_162)
                a.expectEqual(row?.contextPercent, 24)
                a.expectEqual(row?.status, "working", "the mod adds a figure, never a colour")
                app.sendHook(HookPayloads.sessionEnd(sessionId: sessionId, cwd: LifecycleSuite.workspace))
            },

            TestCase("a measure for a session the hooks never announced makes no row") { a in
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: measure(stranger, tokens: 9)).status, 204)
                Thread.sleep(forTimeInterval: 0.3)
                a.expectEqual(app.status(of: stranger), "absent")
            },
        ])
    }
}
