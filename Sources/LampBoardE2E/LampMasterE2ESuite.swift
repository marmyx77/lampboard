import LampBoardCore
import Foundation
import TestKit

/// LampMaster's round in the real binary, against a fake `claude`.
///
/// The fake is a shell script in the fake home's `~/.local/bin`, the only place
/// the binary looks under `LAMPBOARD_HOME`. It writes down what it was given on
/// standard input and as arguments, counts its calls, and prints an envelope
/// fixed by each case — so a case can prove the frame went in through the pipe,
/// the validator dropped what it should, and a skip never reached `claude`.
///
/// Each case starts its own instance: the switch, the model and the deadline
/// are preferences, read from a domain that has to be written before launch.
enum LampMasterE2ESuite {

    static let sessionId = "e2e1a2b3-0000-4000-8000-00000000d0c5"
    static let answer = "The docs build is ready. Shall I publish it to staging?"

    static func envelope(_ suggestions: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"total_cost_usd":0.01,"#
            + #""usage":{"input_tokens":10,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0,"output_tokens":200},"#
            + #""structured_output":{"notebook":"watching the docs build","suggestions":["# + suggestions + "]}}"
    }

    static let goodAndInvented = envelope(
        #"{"kind":"stalled","sessions":["e2e1a2b3"],"text":"The docs build waits for a yes.","#
            + #""evidence":"It asked \"Shall I publish it to staging?\" and nobody answered.","action":{"kind":"open"},"#
            + #""confidence":0.8,"key":"docs build waiting"},"#
            + #"{"kind":"cross","sessions":["e2e1a2b3"],"text":"Invented.","evidence":"It said \"the deployment to production failed twice\".","#
            + #""action":{"kind":"none"},"confidence":0.9,"key":"invented"}"#
    )

    static let editorId = "f00dcafe-0000-4000-8000-0000000000ed"
    static let failingId = "badc0de0-0000-4000-8000-0000000000fa"

    static let askReply = envelope("").replacingOccurrences(
        of: #""structured_output":{"notebook":"watching the docs build","suggestions":[]}"#,
        with: #""structured_output":{"answer":"The docs build waits for a yes before staging.","#
            + #""sources":[{"session":"e2e1a2b3","quote":"Shall I publish it to staging?"},"#
            + #"{"session":"e2e1a2b3","quote":"I published it to production already"}],"#
            + #""askSession":{"id":"e2e1a2b3","question":"Publish the docs to staging?"},"confidence":0.8}"#)

    /// One instance with LampMaster's preferences, its fake `claude`, and a
    /// closed conversation from a minute ago.
    final class Bench {
        let app: AppUnderTest
        let domain: String
        var bin: URL { app.home.appendingPathComponent(".local/bin") }
        var folder: URL { app.home.appendingPathComponent(".lampboard/lampmaster") }

        init(binaryURL: URL, port: UInt16, enabled: Bool = true, timeout: Double? = nil) {
            app = AppUnderTest(binaryURL: binaryURL, port: port)
            domain = "com.lampboard.app.test.\(app.home.lastPathComponent)"
            let defaults = UserDefaults(suiteName: domain)
            defaults?.removePersistentDomain(forName: domain)
            defaults?.set(enabled, forKey: "lampmaster.enabled")
            defaults?.set("sonnet", forKey: "lampmaster.model")
            if let timeout { defaults?.set(timeout, forKey: "lampmaster.timeoutSeconds") }
            defaults?.synchronize()
        }

        func start(reply: String, sleeping: Bool = false) throws {
            try app.start()
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try reply.write(to: bin.appendingPathComponent("reply.json"), atomically: true, encoding: .utf8)
            let script = """
            #!/bin/sh
            here="$(dirname "$0")"
            cat > "$here/stdin.txt"
            printf '%s\\n' "$@" > "$here/args.txt"
            echo call >> "$here/calls.txt"
            \(sleeping ? "exec /bin/sleep 30" : "cat \"$here/reply.json\"")
            """
            let fake = bin.appendingPathComponent("claude")
            try script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            writeConversation()
        }

        func stop() {
            app.stop()
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }

        /// A closed conversation that asked something a minute ago: in the
        /// frame for six hours.
        func writeConversation() {
            let folder = app.home.appendingPathComponent(".claude/projects/-home-dev-docs-site")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
            let records: [[String: Any]] = [
                ["type": "user", "timestamp": stamp, "cwd": "/home/dev/docs-site", "entrypoint": "cli",
                 "message": ["role": "user", "content": "build the docs site"]],
                ["type": "assistant", "timestamp": stamp, "cwd": "/home/dev/docs-site", "entrypoint": "cli",
                 "message": ["role": "assistant", "model": "claude-sonnet-5-5",
                             "content": [["type": "text", "text": LampMasterE2ESuite.answer]]]],
            ]
            let text = records.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            try? text.write(to: folder.appendingPathComponent("\(LampMasterE2ESuite.sessionId).jsonl"),
                            atomically: true, encoding: .utf8)
        }

        /// A session that wrote a file a minute ago: what `overlaps` finds.
        func writeEditor() {
            let folder = app.home.appendingPathComponent(".claude/projects/-home-dev-docs-site")
            let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
            let records: [[String: Any]] = [
                ["type": "assistant", "timestamp": stamp, "cwd": "/home/dev/docs-site", "entrypoint": "cli",
                 "message": ["role": "assistant", "model": "claude-sonnet-5-5", "content": [
                     ["type": "tool_use", "id": "w1", "name": "Edit", "input": ["file_path": "/home/dev/docs-site/src/build.ts"]]]]],
                ["type": "user", "timestamp": stamp, "cwd": "/home/dev/docs-site", "entrypoint": "cli",
                 "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "w1", "content": "ok"]]]],
            ]
            let text = records.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            try? text.write(to: folder.appendingPathComponent("\(LampMasterE2ESuite.editorId).jsonl"),
                            atomically: true, encoding: .utf8)
        }

        /// A session whose `npm run deploy` failed three times in the last
        /// minutes, the same way: a repeated failure, so a quick round (D72).
        func writeFailing() {
            let folder = app.home.appendingPathComponent(".claude/projects/-home-dev-api")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let asked = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-6 * 60))
            var records: [[String: Any]] = [
                ["type": "user", "timestamp": asked, "cwd": "/home/dev/api", "entrypoint": "cli", "origin": ["kind": "human"],
                 "message": ["role": "user", "content": "deploy the api"]],
            ]
            for attempt in 1...3 {
                let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(attempt - 5) * 60))
                records.append(["type": "assistant", "timestamp": stamp, "cwd": "/home/dev/api", "entrypoint": "cli",
                                "message": ["role": "assistant", "model": "claude-sonnet-5-5", "content": [
                                    ["type": "tool_use", "id": "d\(attempt)", "name": "Bash", "input": ["command": "npm run deploy"]]]]])
                records.append(["type": "user", "timestamp": stamp, "cwd": "/home/dev/api", "entrypoint": "cli",
                                "message": ["role": "user", "content": [
                                    ["type": "tool_result", "tool_use_id": "d\(attempt)", "is_error": true,
                                     "content": "npm ERR! missing script: deploy"]]]])
            }
            let text = records.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            try? text.write(to: failingTranscript, atomically: true, encoding: .utf8)
        }

        var failingTranscript: URL {
            app.home.appendingPathComponent(".claude/projects/-home-dev-api/\(LampMasterE2ESuite.failingId).jsonl")
        }

        /// `lampboard mcp` as Claude Code starts it: the session's id in the
        /// environment, JSON-RPC in on standard input. Returns the answers by id.
        func mcp(as session: String, _ lines: [String]) -> [Int: [String: Any]] {
            let process = Process()
            process.executableURL = app.binaryPath
            process.arguments = ["mcp", "--port", String(app.port)]
            var environment = ProcessInfo.processInfo.environment
            environment[AppConfig.homeOverrideVariable] = app.home.path
            environment["CLAUDE_CODE_SESSION_ID"] = session
            process.environment = environment
            process.currentDirectoryURL = app.home
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [:] }
            input.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var answers: [Int: [String: Any]] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                answers[id] = object
            }
            return answers
        }

        func ask() -> Int { app.raw(method: "POST", path: AppConfig.lampMasterPath).status }

        func state() -> [String: Any]? {
            let result = app.raw(method: "GET", path: AppConfig.lampMasterPath)
            guard result.status == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(result.body.utf8)) as? [String: Any]
        }

        var lastRound: [String: Any]? { state()?["lastRound"] as? [String: Any] }
        var open: [[String: Any]] { state()?["open"] as? [[String: Any]] ?? [] }

        func calls() -> Int {
            ((try? String(contentsOf: bin.appendingPathComponent("calls.txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }

        func read(_ name: String) -> String {
            (try? String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }

        /// Asks for a round and waits until one more is recorded. Counted, not
        /// timed: two rounds within a second carry the same stamp.
        @discardableResult
        func round(timeout: TimeInterval = 15) -> [String: Any]? {
            let before = state()?["roundsToday"] as? Int ?? 0
            guard ask() == 202 else { return nil }
            app.waitUntil(timeout: timeout) {
                guard let now = state(), now["running"] as? Bool == false else { return false }
                return (now["roundsToday"] as? Int ?? 0) > before
            }
            return lastRound
        }
    }

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        func bench(enabled: Bool = true, timeout: Double? = nil, reply: String = goodAndInvented,
                   sleeping: Bool = false, _ t: Assertions, _ body: (Bench) -> Void) {
            let bench = Bench(binaryURL: binaryURL, port: port, enabled: enabled, timeout: timeout)
            defer { bench.stop() }
            do { try bench.start(reply: reply, sleeping: sleeping) } catch {
                return t.fail("the instance did not start: \(error)")
            }
            body(bench)
        }

        return TestSuite("E2E · LampMaster", [

            TestCase("a round reaches claude with the frame on standard input, and the validator screens the answer") { t in
                bench(t) { bench in
                    let round = bench.round()
                    t.expectEqual(round?["outcome"] as? String, "ran", "the round ran")
                    t.expectEqual(round?["shown"] as? Int, 1, "one suggestion shown")
                    t.expectEqual((round?["rejected"] as? [String: Int])?["noEvidence"], 1, "the invented one dropped")
                    t.expectEqual(round?["tokens"] as? Int, 3_210, "tokens as billed")
                    t.expectEqual(bench.open.compactMap { ($0["suggestion"] as? [String: Any])?["key"] as? String },
                                  ["docs build waiting"])
                    let stdin = bench.read("stdin.txt"), args = bench.read("args.txt")
                    t.expect(stdin.contains("<frame>") && stdin.contains("e2e1a2b3"), "the frame came on stdin")
                    t.expect(stdin.contains(answer), "with the session's last answer")
                    t.expect(!args.contains("<frame>") && !args.contains(answer), "and not as an argument")
                    for flag in ["--no-session-persistence", "--strict-mcp-config", #"{"disableAllHooks":true}"#] {
                        t.expect(args.contains(flag), "\(flag) passed")
                    }
                    let mode = (try? FileManager.default.attributesOfItem(atPath: bench.folder.path))?[.posixPermissions] as? Int
                    t.expectEqual(mode, 0o700, "the folder is the owner's")
                    t.expect(FileManager.default.fileExists(atPath: bench.folder.appendingPathComponent("notebook.md").path),
                             "the notebook is kept")
                }
            },

            TestCase("a second round with nothing new is skipped without calling claude") { t in
                bench(t) { bench in
                    bench.round()
                    let again = bench.round()
                    t.expectEqual(again?["outcome"] as? String, "skipped", "skipped")
                    t.expectEqual(again?["skip"] as? String, "unchanged", "because nothing changed")
                    t.expectEqual(bench.calls(), 1, "claude was called once")
                }
            },

            TestCase("a failure repeated three times brings a quick round with Sonnet at the turn's end") { t in
                bench(t) { bench in
                    bench.writeFailing()
                    let stop = HookPayloads.stop(sessionId: LampMasterE2ESuite.failingId, cwd: "/home/dev/api")
                        .merging(["transcript_path": bench.failingTranscript.path]) { _, new in new }
                    bench.app.sendHook(stop)
                    let ran = bench.app.waitUntil(timeout: 15) {
                        (bench.lastRound?["trigger"] as? String) == "quick" && bench.state()?["running"] as? Bool == false
                    }
                    t.expect(ran, "a quick round, without anybody asking: \(String(describing: bench.lastRound))")
                    t.expectEqual(bench.lastRound?["model"] as? String, "sonnet", "the quick round's model")
                    t.expect(bench.read("args.txt").contains("sonnet"), "claude was told so")
                    let urgent = bench.lastRound?["urgent"] as? [String] ?? []
                    t.expect(urgent.contains { $0.hasPrefix("badc0de0 failure") }, "the pair it looked at is kept: \(urgent)")

                    // A second turn's end within the minute is not a second look.
                    bench.app.sendHook(stop)
                    Thread.sleep(forTimeInterval: 2)
                    t.expectEqual(bench.calls(), 1, "claude was called once")
                }
            },

            TestCase("a failure another project met before reaches the round as a precedent, found in the index (D3)") { t in
                bench(t) { bench in
                    bench.writeFailing()
                    let dir = bench.app.home.appendingPathComponent(".claude/projects/-home-dev-infra")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let then = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400 * 3))
                    let lines: [[String: Any]] = [
                        ["type": "user", "uuid": "u1", "timestamp": then, "cwd": "/home/dev/infra", "origin": ["kind": "human"],
                         "message": ["role": "user", "content": "npm says missing script deploy in the infra repo"]],
                        ["type": "assistant", "uuid": "a1", "timestamp": then,
                         "message": ["role": "assistant", "content": [["type": "text", "text":
                            "Added a deploy script to package.json: the script deploy now runs the pipeline."]]]],
                    ]
                    let text = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                        .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
                    try? text.write(to: dir.appendingPathComponent("1f1f1f1f-0000-4000-8000-000000000001.jsonl"), atomically: true, encoding: .utf8)
                    // The index built now, as the panel's own pass would within thirty seconds.
                    _ = bench.app.runCommand(["search", "deploy"])
                    let round = bench.round()
                    t.expectEqual(round?["outcome"] as? String, "ran", "the round ran")
                    let stdin = bench.read("stdin.txt")
                    t.expect(stdin.contains("\"precedents\""), "the frame has precedents")
                    t.expect(stdin.contains("\"1f1f1f1f\"") && stdin.contains("\"infra\""), "the other project's conversation, by id and project")
                    t.expect(stdin.contains("«deploy»") || stdin.contains("«script»"), "with what was said around the match: \(stdin.suffix(600))")
                    t.expect(stdin.contains("\"session\":\"badc0de0\""), "for the failing session")
                }
            },

            TestCase("past the day's ceiling no round reaches claude") { t in
                bench(t) { bench in
                    let spent = LampMasterRound(at: Date(), trigger: .timer, outcome: .ran, tokens: 200_000, digest: "earlier")
                    try? FileManager.default.createDirectory(at: bench.folder, withIntermediateDirectories: true)
                    try? ((LampMasterLedger.line(spent) ?? "") + "\n")
                        .write(to: bench.folder.appendingPathComponent("rounds.jsonl"), atomically: true, encoding: .utf8)
                    let round = bench.round()
                    t.expectEqual(round?["skip"] as? String, "dailyCap", "the ceiling")
                    t.expectEqual(bench.calls(), 0, "claude never called")
                }
            },

            TestCase("a claude that does not answer is stopped at the deadline") { t in
                bench(timeout: 2, sleeping: true, t) { bench in
                    t.expectEqual(bench.ask(), 202, "accepted")
                    t.expectEqual(bench.state()?["running"] as? Bool, true, "the state says a round is in flight")
                    t.expectEqual(bench.ask(), 409, "a second request while it runs is refused, and says so")
                    bench.app.waitUntil(timeout: 20) { bench.state()?["running"] as? Bool == false }
                    let round = bench.lastRound
                    t.expectEqual(round?["outcome"] as? String, "failed", "failed")
                    t.expectEqual(round?["failure"] as? String, "timedOut", "at the deadline")
                    t.expect(bench.open.isEmpty, "nothing shown")
                }
            },

            TestCase("an answer outside the schema is a failed round, never half a suggestion") { t in
                let prose = #"{"type":"result","subtype":"success","is_error":false,"result":"Here are my thoughts."}"#
                bench(reply: prose, t) { bench in
                    let round = bench.round()
                    t.expectEqual(round?["failure"] as? String, "offSchema", "off schema")
                    t.expect(bench.open.isEmpty, "nothing shown")
                }
            },

            TestCase("switched off, a request is recorded as skipped and claude is never called") { t in
                bench(enabled: false, t) { bench in
                    let round = bench.round()
                    t.expectEqual(round?["skip"] as? String, "off", "off")
                    t.expectEqual(bench.calls(), 0, "claude never called")
                }
            },

            TestCase("a session asks through lampboard mcp: the lookups answer from the cards, without the asker") { t in
                bench(t) { bench in
                    bench.writeEditor()
                    let call = { (id: Int, tool: String, args: String) in
                        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#
                    }
                    let lines = [
                        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                        call(3, "overlaps", #"{"files":["src/build.ts"]}"#),
                        call(4, "who_knows", #"{"topic":"docs site build"}"#),
                    ]
                    let text = { (answer: [String: Any]?) in
                        ((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    }
                    let answers = bench.mcp(as: "0000aaaa-asker", lines)
                    t.expectEqual(((answers[1]?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "lampmaster")
                    t.expectEqual(((answers[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, 4, "four tools")
                    t.expect(text(answers[3]).contains("f00dcafe") && text(answers[3]).contains("build.ts"), "overlaps: \(text(answers[3]))")
                    t.expect(text(answers[4]).contains("e2e1a2b3"), "who_knows: \(text(answers[4]))")
                    t.expect(!text(answers[4]).contains(answer), "never the other session's words")
                    let own = bench.mcp(as: editorId, [call(5, "overlaps", #"{"files":["src/build.ts"]}"#)])
                    t.expect(text(own[5]).contains("No other session"), "the asker is not its own overlap: \(text(own[5]))")
                    t.expect(text(answers[3]).hasPrefix(LampMasterMCP.dataNotice), "every result opens with the notice")
                    t.expectEqual(bench.calls(), 0, "no model ran for a lookup")
                }
            },

            TestCase("who_knows names an earlier conversation from the search index, never its words (D89)") { t in
                bench(t) { bench in
                    let dir = bench.app.home.appendingPathComponent(".claude/projects/-home-dev-docs")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    // Older than the week the cards cover: only the index remembers it.
                    let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400 * 20))
                    let lines: [[String: Any]] = [
                        ["type": "user", "uuid": "u1", "timestamp": now, "cwd": "/home/dev/docs", "origin": ["kind": "human"],
                         "message": ["role": "user", "content": "The quokka migration broke the docs site build"]],
                        ["type": "custom-title", "customTitle": "Docs build fix"],
                    ]
                    let text = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                        .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
                    let file = dir.appendingPathComponent("dddddddd-0000-4000-8000-000000000004.jsonl")
                    try? text.write(to: file, atomically: true, encoding: .utf8)
                    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400 * 20)], ofItemAtPath: file.path)
                    _ = bench.app.runCommand(["search", "docs"])
                    let answers = bench.mcp(as: "0000aaaa-asker", [
                        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"who_knows","arguments":{"topic":"docs site build"}}}"#,
                    ])
                    let said = ((answers[2]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    t.expect(said.contains("Said in earlier conversations") && said.contains("\u{201C}Docs build fix\u{201D} in docs"), "named: \(said)")
                    t.expect(!said.contains("quokka"), "never its words")
                    t.expectEqual(bench.calls(), 0, "no model ran")
                }
            },

            TestCase("ask_lampmaster runs claude once, keeps only real sources, and answers a repeat for free") { t in
                bench(reply: askReply, t) { bench in
                    let question = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ask_lampmaster","arguments":{"question":"Is anything waiting on the docs build?"}}}"#
                    let first = bench.mcp(as: "0000aaaa-asker", [question])
                    let text = ((first[7]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    t.expect(text.hasPrefix(LampMasterMCP.dataNotice + "\nThe docs build waits for a yes"), text)
                    t.expect(!bench.read("stdin.txt").contains("watching the docs build"), "no notebook in a question's frame")
                    let asks = (try? String(contentsOf: bench.folder.appendingPathComponent("asks.jsonl"), encoding: .utf8)) ?? ""
                    t.expectEqual(asks.split(separator: "\n").count, 1, "the booking became the answer, not a second line")
                    t.expect(text.contains("Shall I publish it to staging?"), "the real source stays")
                    t.expect(!text.contains("production already"), "the invented one goes")
                    t.expect(text.contains("only the user"), "the referral says who sends it")
                    t.expect(bench.read("stdin.txt").contains("<question>"), "the question went on stdin")
                    let again = bench.mcp(as: "0000aaaa-asker", [question])
                    t.expectNotNil(again[7], "answered again")
                    t.expectEqual(bench.calls(), 1, "the repeat cost nothing")
                }
            },

            TestCase("mcp install registers through claude, uninstall-hooks takes it out again") { t in
                bench(t) { bench in
                    let install = bench.app.runCommand(["mcp", "install", "--port", String(bench.app.port)])
                    t.expectEqual(install.status, 0, "installed: \(install.output)")
                    let args = bench.read("args.txt").split(separator: "\n").map(String.init)
                    t.expectEqual(Array(args.prefix(6)), ["mcp", "add", "--scope", "user", "lampmaster", "--"], "claude's own command")
                    t.expectEqual(Array(args.suffix(3)), ["mcp", "--port", String(bench.app.port)], "this binary, on this port")
                    // What claude would have written, so the uninstall sees it.
                    let config = bench.app.home.appendingPathComponent(".claude.json")
                    try? #"{"mcpServers":{"lampmaster":{"type":"stdio","command":"/x","args":["mcp"]}}}"#
                        .write(to: config, atomically: true, encoding: .utf8)
                    t.expectEqual(bench.app.runCommand(["mcp", "status"]).output.contains("is registered"), true, "status reads the file")
                    let uninstall = bench.app.runCommand(["uninstall-hooks"])
                    t.expect(uninstall.output.contains("lampmaster MCP server removed"), "uninstall-hooks: \(uninstall.output)")
                    t.expectEqual(bench.read("args.txt").split(separator: "\n").map(String.init),
                                  ["mcp", "remove", "--scope", "user", "lampmaster"], "removed with claude's own command")
                }
            },

            TestCase("the state and the round are behind the token") { t in
                bench(t) { bench in
                    t.expectEqual(bench.app.raw(method: "GET", path: AppConfig.lampMasterPath, token: .some(nil)).status, 401)
                    t.expectEqual(bench.app.raw(method: "POST", path: AppConfig.lampMasterPath, token: .some("wrong")).status, 401)
                    t.expectEqual(bench.app.raw(method: "POST", path: AppConfig.lampMasterToolPath, token: .some(nil),
                                                body: #"{"tool":"who_knows","arguments":{"topic":"docs"}}"#).status, 401, "the lookups too")
                    t.expectEqual(bench.calls(), 0, "claude never called")
                }
            },
        ])
    }
}
