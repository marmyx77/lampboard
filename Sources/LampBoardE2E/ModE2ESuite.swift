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

            TestCase("/handoff (D91): behind the token, proven with the permission key, POST only") { a in
                let body = #"{"v":1,"session":"\#(sessionId)","to":"api","text":"Slots renamed; tests left."}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.handoffPath, token: .some(nil), body: body).status, 401)
                a.expectEqual(app.raw(method: "GET", path: AppConfig.handoffPath).status, 405)
                // As the mod sends it: a nonce and its HMAC over the fields, never the key.
                func send(key: String) -> String {
                    let nonce = UUID().uuidString
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(app.port)\(AppConfig.handoffPath)")!)
                    request.httpMethod = "POST"
                    request.setValue(app.tokenValue, forHTTPHeaderField: AccessToken.headerName)
                    request.setValue(nonce, forHTTPHeaderField: "X-LampBoard-Nonce")
                    request.setValue(PermissionGate.mac(key: key, message: "handoff:\(nonce):\(sessionId):api:Slots renamed; tests left."),
                                     forHTTPHeaderField: "X-LampBoard-Proof")
                    request.httpBody = Data(body.utf8)
                    let done = DispatchSemaphore(value: 0)
                    var said = ""
                    URLSession.shared.dataTask(with: request) { data, _, _ in
                        said = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        done.signal()
                    }.resume()
                    _ = done.wait(timeout: .now() + 10)
                    return said
                }
                a.expectEqual(send(key: app.tokenValue ?? ""), "LampBoard could not read the handoff, or it was not proven.",
                              "the token is not the key")
                a.expectEqual(send(key: app.checkKeyValue ?? ""), "LampBoard's panel is not ready.", "proven, and headless: nothing proposed")
            },

            TestCase("the decision board (D105): pinned, listed and taken off from the command line, kept 0600") { a in
                let port = ["--port", String(app.port)]
                let pinned = app.runCommand(["decide", "e2e-board", "Dates", "are", "UTC."] + port)
                a.expectEqual(pinned.status, 0, pinned.output)
                a.expect(pinned.output.contains("e2e-board:\n  1. Dates are UTC."), pinned.output)
                let again = app.runCommand(["decide", "e2e-board", "dates are utc."] + port)
                a.expectEqual(again.status, 1, "the same words refused")
                a.expect(again.output.contains(DecisionBoardError.duplicate.sentence), again.output)
                a.expect(app.runCommand(["decisions"] + port).output.contains("1. Dates are UTC."), "listed")
                let mode = (try? FileManager.default.attributesOfItem(
                    atPath: app.home.appendingPathComponent(".lampboard/decisions.json").path))?[.posixPermissions] as? NSNumber
                a.expectEqual(mode?.int16Value, 0o600)
                let words = app.runCommand(["decide", "e2e-board", "Dev", "servers", "use", "--port", "80"] + port)
                a.expect(words.output.contains("2. Dev servers use --port 80"), "a port in the words stays in the words: \(words.output)")
                a.expectEqual(app.runCommand(["undecide", "e2e-board", "2"] + port).status, 0)
                let off = app.runCommand(["undecide", "e2e-board", "1"] + port)
                a.expect(off.output.contains("e2e-board: no decisions pinned."), off.output)
                a.expectEqual(app.raw(method: "POST", path: AppConfig.decisionsPath, token: .some(nil), body: "{}").status, 401)
            },

            TestCase("/mod/decisions answers a proven session with its repository's board, signed; unproven, nothing") { a in
                let id = "e2e0d0d0-0000-4000-8000-0000000000cc"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: LifecycleSuite.workspace), repo: "e2e-board-mod")
                guard app.waitUntil({ app.status(of: id) == "working" }) else { return a.fail("no row: \(app.status(of: id))") }
                defer { app.sendHook(HookPayloads.sessionEnd(sessionId: id, cwd: LifecycleSuite.workspace)) }
                let port = ["--port", String(app.port)]
                a.expectEqual(app.runCommand(["decide", "e2e-board-mod", "Keys are tenant_id."] + port).status, 0)
                defer { app.runCommand(["undecide", "e2e-board-mod", "1"] + port) }
                let key = app.checkKeyValue ?? ""
                func ask(session: String, key: String?) -> String {
                    let nonce = UUID().uuidString
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(app.port)\(AppConfig.modDecisionsPath)")!)
                    request.httpMethod = "POST"
                    request.setValue(app.tokenValue, forHTTPHeaderField: AccessToken.headerName)
                    request.setValue(nonce, forHTTPHeaderField: "X-LampBoard-Nonce")
                    if let key {
                        request.setValue(PermissionGate.mac(key: key, message: DecisionBoardExchange.proofMessage(nonce: nonce, session: session)),
                                         forHTTPHeaderField: "X-LampBoard-Proof")
                    }
                    request.httpBody = Data(#"{"v":1,"session":"\#(session)"}"#.utf8)
                    let done = DispatchSemaphore(value: 0)
                    var said = ""
                    URLSession.shared.dataTask(with: request) { data, _, _ in
                        said = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        done.signal()
                    }.resume()
                    _ = done.wait(timeout: .now() + 10)
                    guard let cut = said.firstIndex(of: "\n") else { return said }
                    let head = said[..<cut].split(separator: " ").map(String.init)
                    let text = String(said[said.index(after: cut)...])
                    guard head.count == 3, head[2] == PermissionGate.mac(key: key ?? "",
                        message: DecisionBoardExchange.signedMessage(nonce: nonce, version: head[1], text: text))
                    else { return "unsigned: " + said }
                    return head[1] + "|" + text
                }
                let answer = ask(session: id, key: key)
                a.expect(answer.contains("|") && answer.contains("1. Keys are tenant_id.") && answer.contains("e2e-board-mod"), answer)
                a.expect(answer.prefix(16).allSatisfy(\.isHexDigit), "a version: \(answer.prefix(20))")
                a.expectEqual(ask(session: id, key: nil), "", "no proof, no board")
                a.expectEqual(ask(session: id, key: app.tokenValue), "", "the token is not the key")
                a.expectEqual(ask(session: stranger, key: key), "", "a session the panel does not know: no answer, not \"nothing pinned\"")
                let bare = "e2e0d0d0-0000-4000-8000-0000000000dd"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: bare, cwd: LifecycleSuite.workspace))
                defer { app.sendHook(HookPayloads.sessionEnd(sessionId: bare, cwd: LifecycleSuite.workspace)) }
                if app.waitUntil({ app.status(of: bare) == "working" }) {
                    a.expectEqual(ask(session: bare, key: key), "-|", "a session with no repository: nothing pinned")
                } else { a.fail("no row for the session without a repository") }
            },

            TestCase("/mod/governor answers a proven session with the model it was lowered to, signed; unproven, nothing (G3)") { a in
                let own = AppUnderTest(binaryURL: binaryURL, port: port)
                defer { own.stop() }
                do { try own.start() } catch { return a.fail("instance did not start: \(error)") }
                // The plan as the panel writes it; read again because the file moved.
                let plan = GovernorPlan().lowering(sessionId, to: "claude-sonnet-5-5", until: Date().addingTimeInterval(3600))
                let file = own.home.appendingPathComponent(".lampboard/governor.json")
                try? GovernorPlan.encode(plan).write(to: file)
                func ask(_ session: String, key: String?) -> String {
                    let nonce = UUID().uuidString
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(AppConfig.modGovernorPath)")!)
                    request.httpMethod = "POST"
                    request.setValue(own.tokenValue, forHTTPHeaderField: AccessToken.headerName)
                    request.setValue(nonce, forHTTPHeaderField: "X-LampBoard-Nonce")
                    if let key {
                        request.setValue(PermissionGate.mac(key: key, message: GovernorExchange.proofMessage(nonce: nonce, session: session)),
                                         forHTTPHeaderField: "X-LampBoard-Proof")
                    }
                    request.httpBody = Data(#"{"v":1,"session":"\#(session)"}"#.utf8)
                    let done = DispatchSemaphore(value: 0)
                    var said = ""
                    URLSession.shared.dataTask(with: request) { data, _, _ in
                        said = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        done.signal()
                    }.resume()
                    _ = done.wait(timeout: .now() + 10)
                    let parts = said.split(separator: " ").map(String.init)
                    guard parts.count == 3, parts[2] == PermissionGate.mac(key: key ?? "", message: "governed:\(nonce):\(parts[1])")
                    else { return "unsigned: " + said }
                    return parts[1]
                }
                let key = own.checkKeyValue ?? ""
                a.expectEqual(ask(sessionId, key: key), "claude-sonnet-5-5", "lowered, signed")
                a.expectEqual(ask(stranger, key: key), "-", "another session: its own model")
                a.expectEqual(ask(sessionId, key: nil), "unsigned: ", "no proof, no answer")
                let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
                a.expect(mode != nil, "the plan is where the panel reads it")
            },

            TestCase("/mod/radar: a file another live session wrote is answered with a signed sentence; unproven, nothing (§4.4)") { a in
                let writer = "e2e0d0d0-0000-4000-8000-0000000000ee"
                let file = "/tmp/e2e-radar/src/routes.ts"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: writer, cwd: LifecycleSuite.workspace))
                guard app.waitUntil({ app.status(of: writer) == "working" }) else { return a.fail("no row for the writer") }
                defer { app.sendHook(HookPayloads.sessionEnd(sessionId: writer, cwd: LifecycleSuite.workspace)) }
                let report = #"{"v":1,"kind":"tool","session":"\#(writer)","id":"c1","tool":"Edit","phase":"start","detail":"\#(file)"}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: report).status, 204)
                let key = app.checkKeyValue ?? ""
                func ask(_ session: String, key: String?) -> String {
                    let nonce = UUID().uuidString
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(app.port)\(AppConfig.modRadarPath)")!)
                    request.httpMethod = "POST"
                    request.setValue(app.tokenValue, forHTTPHeaderField: AccessToken.headerName)
                    request.setValue(nonce, forHTTPHeaderField: "X-LampBoard-Nonce")
                    if let key {
                        request.setValue(PermissionGate.mac(key: key, message: RadarExchange.proofMessage(nonce: nonce, session: session, file: file)),
                                         forHTTPHeaderField: "X-LampBoard-Proof")
                    }
                    request.httpBody = Data(#"{"v":1,"session":"\#(session)","file":"\#(file)"}"#.utf8)
                    let done = DispatchSemaphore(value: 0)
                    var said = ""
                    URLSession.shared.dataTask(with: request) { data, _, _ in
                        said = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        done.signal()
                    }.resume()
                    _ = done.wait(timeout: .now() + 10)
                    return said
                }
                a.expect(app.waitUntil { ask(sessionId, key: key).contains("routes.ts was written by") },
                         "another session's write: \(ask(sessionId, key: key))")
                a.expect(ask(writer, key: key).hasPrefix("clear "), "its own write is no warning")
                a.expectEqual(ask(sessionId, key: nil), "", "no proof, no answer")
            },

            TestCase("/mod/hold: with nobody away a destructive command goes, signed; unproven, nothing (A2)") { a in
                let key = app.checkKeyValue ?? "", command = "echo ok\\nrm -rf build"
                func ask(key: String?) -> String {
                    let nonce = UUID().uuidString
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(app.port)\(AppConfig.modHoldPath)")!)
                    request.httpMethod = "POST"
                    request.setValue(app.tokenValue, forHTTPHeaderField: AccessToken.headerName)
                    request.setValue(nonce, forHTTPHeaderField: "X-LampBoard-Nonce")
                    if let key {
                        request.setValue(PermissionGate.mac(key: key, message: HoldExchange.proofMessage(nonce: nonce, session: sessionId, cut: false, command: "echo ok\nrm -rf build")),
                                         forHTTPHeaderField: "X-LampBoard-Proof")
                    }
                    request.httpBody = Data(#"{"v":1,"session":"\#(sessionId)","command":"\#(command)","cut":false}"#.utf8)
                    let done = DispatchSemaphore(value: 0)
                    var said = ""
                    URLSession.shared.dataTask(with: request) { data, _, _ in
                        said = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        done.signal()
                    }.resume()
                    _ = done.wait(timeout: .now() + 10)
                    return said
                }
                // The headless instance has no one to be away: a destructive line goes.
                a.expect(ask(key: key).hasPrefix("go "), "here, it goes: \(ask(key: key))")
                a.expectEqual(ask(key: nil), "", "no proof, no answer")
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
                a.expectEqual(row?.costUSD, 0.0968, "and the cost")
                app.sendHook(HookPayloads.sessionEnd(sessionId: sessionId, cwd: LifecycleSuite.workspace))
            },

            TestCase("a measure for a session the hooks never announced makes no row") { a in
                a.expectEqual(app.raw(method: "POST", path: AppConfig.modPath, body: measure(stranger, tokens: 9)).status, 204)
                Thread.sleep(forTimeInterval: 0.3)
                a.expectEqual(app.status(of: stranger), "absent")
            },

            // A fake `claude` that writes down what it was asked, and with which
            // home, and writes what the real one wrote when measured on the test
            // Mac: `enabledPlugins` in the settings, the version in its records.
            TestCase("mod install goes through claude in the fake home, uninstall-hooks takes it out") { a in
                let bench = AppUnderTest(binaryURL: binaryURL, port: port &+ 1)
                let home = bench.home
                defer { try? FileManager.default.removeItem(at: home) }
                let bin = home.appendingPathComponent(".local/bin")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let script = """
                    #!/bin/sh
                    [ "$1" = "--version" ] && { echo "2.1.289 (Claude Code)"; exit 0; }
                    echo "$HOME | $*" >> "$HOME/claude-calls.txt"
                    mkdir -p "$HOME/.claude/plugins"
                    case "$1 $2" in
                      "plugin install") [ -f "$HOME/fail-install" ] && { echo "install refused"; exit 1; }
                         echo '{"enabledPlugins":{"lampboard@lampboard":true}}' > "$HOME/.claude/settings.json"
                        echo '{"version":2,"plugins":{"lampboard@lampboard":[{"version":"\(ModFiles.version)"}]}}' \
                          > "$HOME/.claude/plugins/installed_plugins.json" ;;
                      "plugin uninstall") echo '{"enabledPlugins":{}}' > "$HOME/.claude/settings.json"
                        rm -f "$HOME/.claude/plugins/installed_plugins.json" ;;
                    esac
                    exit 0
                    """
                let fake = bin.appendingPathComponent("claude")
                try? script.write(to: fake, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
                let calls = { (try? String(contentsOf: home.appendingPathComponent("claude-calls.txt"), encoding: .utf8)) ?? "" }

                let install = bench.runCommand(["mod", "install"])
                a.expectEqual(install.status, 0, "installed: \(install.output)")
                let folder = home.appendingPathComponent(".lampboard/mod-marketplace")
                a.expectEqual(calls().split(separator: "\n").map(String.init), [
                    "\(home.path) | plugin marketplace add \(folder.path)",
                    "\(home.path) | plugin install lampboard@lampboard --scope user",
                ], "claude's own commands, with the fake home as HOME")
                for file in ModFiles.all {
                    let written = try? String(contentsOf: folder.appendingPathComponent(file.path), encoding: .utf8)
                    a.expectEqual(written, file.content, file.path)
                }
                a.expect(bench.runCommand(["mod", "status"]).output.contains("is installed (\(ModFiles.version))"), "status")

                // Again over an installed one, as the launch refresh does: out
                // first, then the files, then in.
                try? FileManager.default.removeItem(at: home.appendingPathComponent("claude-calls.txt"))
                a.expectEqual(bench.runCommand(["mod", "install"]).status, 0, "reinstalled")
                a.expectEqual(calls().split(separator: "\n").map { String($0.split(separator: " ")[3]) },
                              ["uninstall", "marketplace", "marketplace", "install"], "out, then in")
                a.expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mod/hooks/register.js").path),
                         "the files are there after a reinstall")

                // A refused install leaves nothing half in: the next try starts
                // clean instead of tripping on a declared marketplace.
                let refusal = home.appendingPathComponent("fail-install")
                FileManager.default.createFile(atPath: refusal.path, contents: Data())
                try? FileManager.default.removeItem(at: home.appendingPathComponent("claude-calls.txt"))
                let refused = bench.runCommand(["mod", "install"])
                a.expectEqual(refused.status, 1, "refused: \(refused.output)")
                a.expect(refused.output.contains("install refused"), "says why: \(refused.output)")
                a.expectEqual(calls().split(separator: "\n").map { String($0.split(separator: " ")[3]) },
                              ["uninstall", "marketplace", "marketplace", "install", "uninstall", "marketplace"],
                              "out, in, refused, out again")
                a.expect(!FileManager.default.fileExists(atPath: folder.path), "no folder left behind")
                try? FileManager.default.removeItem(at: refusal)
                a.expectEqual(bench.runCommand(["mod", "install"]).status, 0, "and the next try works")

                try? FileManager.default.removeItem(at: home.appendingPathComponent("claude-calls.txt"))
                let uninstall = bench.runCommand(["uninstall-hooks"])
                a.expect(uninstall.output.contains("LampBoard mod removed"), "uninstall-hooks: \(uninstall.output)")
                a.expectEqual(calls().split(separator: "\n").map(String.init), [
                    "\(home.path) | plugin uninstall lampboard@lampboard --scope user",
                    "\(home.path) | plugin marketplace remove lampboard",
                ])
                a.expect(!FileManager.default.fileExists(atPath: folder.path), "the carried copy is gone too")
            },
        ])
    }
}
