import LampBoardCore
import Foundation
import TestKit

/// Allow and Deny from the panel in the real binary (D73, D80): the door the
/// companion mod asks through, closed until the switch is on; an ask that is
/// the mod's only if proven with the permission key, never the token, and an
/// answer signed back.
///
/// The answer comes through `/check/answer`, the door the panel's own buttons
/// open in-process; the mod itself is run against a real Claude Code on the
/// test Mac, outside this suite.
enum PermissionE2ESuite {

    static let session = "e2e0c0c0-0000-4000-8000-0000000000cc"

    static func ask(_ call: String) -> String {
        #"{"v":1,"session":"\#(session)","id":"\#(call)","tool":"Bash","detail":"npm publish"}"#
    }

    enum Proof { case key, token, nothing }

    /// An ask as the mod sends it: a nonce and its proof, never the key itself.
    static func check(_ app: AppUnderTest, call: String, nonce: String, proof: Proof = .key) -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(app.port)\(AppConfig.checkPath)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 70
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(nonce, forHTTPHeaderField: "X-LampBoard-Nonce")
        let key = switch proof {
        case .key: app.checkKeyValue ?? ""
        case .token: app.tokenValue ?? ""
        case .nothing: String(repeating: "f", count: 64)
        }
        request.setValue(PermissionGate.mac(key: key, message: PermissionGate.askMessage(nonce: nonce, session: session, call: call)),
                         forHTTPHeaderField: "X-LampBoard-Proof")
        request.httpBody = Data(ask(call).utf8)
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 70)
        return body
    }

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        func instance(on: Bool, _ t: Assertions, _ body: (AppUnderTest) -> Void) {
            let app = AppUnderTest(binaryURL: binaryURL, port: port)
            let domain = "com.lampboard.app.test.\(app.home.lastPathComponent)"
            UserDefaults(suiteName: domain)?.set(on, forKey: "permissions.panel")
            UserDefaults(suiteName: domain)?.synchronize()
            defer {
                app.stop()
                UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            }
            do { try app.start() } catch { return t.fail("the instance did not start: \(error)") }
            body(app)
        }
        let nonce = "0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D"

        return TestSuite("E2E · permissions from the panel", [

            TestCase("an ask not proven with the key is answered ask, unsigned; the list and the answer need the token") { t in
                instance(on: true, t) { app in
                    t.expect(app.checkKeyValue.map { $0.count >= 32 } == true, "a key of its own, written at launch")
                    t.expect(app.checkKeyValue != app.tokenValue, "not the token")
                    t.expectEqual(check(app, call: "toolu_a", nonce: nonce, proof: .nothing), "ask")
                    t.expectEqual(check(app, call: "toolu_t", nonce: nonce, proof: .token), "ask",
                                  "the token proves nothing: every hook carries it to whatever answers on the port")
                    t.expectEqual(app.raw(method: "POST", path: AppConfig.checkAnswerPath, token: .some(nil),
                                          body: #"{"session":"\#(session)","id":"toolu_a","verdict":"allow"}"#).status, 401)
                    t.expectEqual(app.raw(method: "GET", path: AppConfig.checkPath, token: .some(nil)).status, 401)
                    t.expectEqual(app.raw(method: "PUT", path: AppConfig.checkPath).status, 405)
                }
            },

            TestCase("switched off, every ask is answered ask at once, signed: the session's own dialog") { t in
                instance(on: false, t) { app in
                    let started = Date()
                    let reply = check(app, call: "toolu_off", nonce: nonce)
                    t.expectEqual(reply, PermissionGate.signed(.ask, key: app.checkKeyValue ?? "", nonce: nonce))
                    t.expect(Date().timeIntervalSince(started) < 3, "no wait")
                }
            },

            TestCase("a malformed ask is answered ask, never guessed") { t in
                instance(on: true, t) { app in
                    t.expectEqual(app.raw(method: "POST", path: AppConfig.checkPath, body: #"{"v":1,"session":"x y"}"#).body, "ask")
                }
            },

            TestCase("switched on, an ask waits for the panel and gets its answer, signed") { t in
                instance(on: true, t) { app in
                    var reply = ""
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        reply = check(app, call: "toolu_wait", nonce: nonce)
                        done.signal()
                    }
                    Thread.sleep(forTimeInterval: 1)
                    t.expectEqual(done.wait(timeout: .now()), .timedOut, "still waiting after a second")
                    t.expect(app.raw(method: "GET", path: AppConfig.checkPath).body.contains("toolu_wait"), "listed as waiting")
                    let elsewhere = app.raw(method: "POST", path: AppConfig.checkAnswerPath,
                                            body: #"{"session":"e5f6a7b8-0000-4000-8000-000000000002","id":"toolu_wait","verdict":"allow"}"#)
                    t.expectEqual(elsewhere.status, 404, "another session's call is not this one")
                    let answered = app.raw(method: "POST", path: AppConfig.checkAnswerPath,
                                           body: #"{"session":"\#(session)","id":"toolu_wait","verdict":"deny"}"#)
                    t.expectEqual(answered.status, 204)
                    t.expectEqual(done.wait(timeout: .now() + 5), .success, "the ask returned")
                    t.expectEqual(reply, PermissionGate.signed(.deny, key: app.checkKeyValue ?? "", nonce: nonce))
                    let again = app.raw(method: "POST", path: AppConfig.checkAnswerPath,
                                        body: #"{"session":"\#(session)","id":"toolu_wait","verdict":"allow"}"#)
                    t.expectEqual(again.status, 404, "answered once")
                }
            },
        ])
    }
}
