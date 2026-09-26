import LampBoardCore
import Foundation
import TestKit

/// The accounts the Claude application runs Claude Code as, read out of the
/// running processes because it puts them nowhere else.
enum HostedCredentialsSuite {

    private static let team = "sk-ant-oat01-TEAM_token-A1"
    private static let other = "sk-ant-oat01-other-B2"

    /// Shaped like `ps -Eww -axo command=` on the Mac: the command, then the
    /// environment, one process a line.
    private static func line(_ command: String, _ environment: [String]) -> String {
        ([command] + environment).joined(separator: " ")
    }

    private static let listing = [
        line("/Applications/Claude.app/Contents/MacOS/Claude", ["HOME=/Users/x"]),
        line("/Users/x/Library/Application Support/Claude/claude-code/2.1.281/claude --output-format stream-json",
             ["CLAUDE_CODE_ENTRYPOINT=claude-desktop", "CLAUDE_CODE_OAUTH_TOKEN=\(team)", "HOME=/Users/x"]),
        // A server the session started: same token, inherited.
        line("node server.js", ["CLAUDE_CODE_ENTRYPOINT=claude-desktop", "CLAUDE_CODE_OAUTH_TOKEN=\(team)"]),
        line("/usr/local/bin/claude", ["CLAUDE_CODE_OAUTH_TOKEN=\(other)", "CLAUDE_CODE_ENTRYPOINT=cli"]),
    ].joined(separator: "\n")

    private static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private static let limits = """
    {"limits": [{"kind": "session", "percent": 10, "resets_at": null, "scope": null}]}
    """

    /// Runs the node's script on this Mac with an empty home, the way the ssh
    /// wrapper feeds it: on standard input.
    private static func runScript(home: URL) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(RemoteAllowanceScript.script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static let suite = TestSuite("Accounts handed to Claude Code in the environment", [

        TestCase("Each account is found once, in the order the processes run") { t in
            t.expectEqual(HostedCredentials.tokens(inProcessListing: listing), [team, other], "tokens")
        },

        // Anything else that carries the variable is not Claude Code's, and its
        // token is not an account this panel has any business asking about.
        TestCase("A process that is not Claude Code's is not read") { t in
            let stray = line("/usr/bin/some-tool", ["CLAUDE_CODE_OAUTH_TOKEN=\(team)"])
            t.expectEqual(HostedCredentials.tokens(inProcessListing: stray), [], "tokens")
        },

        TestCase("A variable whose name merely ends the same way is not the token") { t in
            let lookalike = line("claude", ["CLAUDE_CODE_ENTRYPOINT=cli", "MY_CLAUDE_CODE_OAUTH_TOKEN=\(team)"])
            t.expectEqual(HostedCredentials.tokens(inProcessListing: lookalike), [], "tokens")
        },

        TestCase("No more accounts are asked about than the ceiling") { t in
            let many = (0..<9).map {
                line("claude", ["CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-n\($0)"])
            }.joined(separator: "\n")
            t.expectEqual(
                HostedCredentials.tokens(inProcessListing: many).count,
                HostedCredentials.maximumAccounts, "tokens"
            )
        },

        TestCase("The profile names the account") { t in
            let profile = Data("""
            {"account": {"email": "design@example.com", "uuid": "u-1", "full_name": "x"},
             "organization": {"uuid": "o-1"}}
            """.utf8)
            t.expectEqual(
                HostedCredentials.account(fromProfile: profile),
                ClaudeAccount(email: "design@example.com", uuid: "u-1"), "account"
            )
            t.expectNil(HostedCredentials.account(fromProfile: Data("{}".utf8)), "an empty profile")
        },

        // The node the application alone works on is signed out there, and its
        // account must still be drawn.
        TestCase("A signed-out node still reports the accounts the application runs there") { t in
            let answer = object("""
            {"account": null, "error": "not signed in",
             "hosted": [{"account": {"email": "design@example.com", "uuid": "u-1"}, "limits": \(limits)}]}
            """)
            let reports = RemoteAllowanceScript.reports(in: answer, host: "node")
            t.expectEqual(reports.map(\.label), ["design@example.com"], "labels")
            t.expectEqual(reports.first?.machine, "node", "machine")
        },

        TestCase("The node's own account comes first, then the hosted ones") { t in
            let answer = object("""
            {"account": {"email": "sam@example.net", "uuid": "u-2"}, "limits": \(limits),
             "hosted": [{"account": {"email": "design@example.com", "uuid": "u-1"}, "limits": \(limits)},
                        {"account": {"email": "broken@example.com"}, "limits": {"limits": []}}]}
            """)
            t.expectEqual(
                RemoteAllowanceScript.reports(in: answer, host: "node").map(\.label),
                ["sam@example.net", "design@example.com"], "labels"
            )
        },

        // An answer from a node still on the previous script has no `hosted` at
        // all, and must read exactly as it did before.
        TestCase("An answer without hosted accounts reads as before") { t in
            let answer = object("""
            {"account": {"email": "sam@example.net", "uuid": "u-2"}, "limits": \(limits)}
            """)
            t.expectEqual(RemoteAllowanceScript.reports(in: answer, host: "node").count, 1, "reports")
        },

        // Executed, not just read: a Python script that only compiles has not been
        // tested. An empty home is a machine signed out, and the answer must still
        // be well-formed JSON with the hosted list in it.
        TestCase("The node's script runs and answers for a signed-out machine") { t in
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("lampboard-hosted-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }

            guard let answer = runScript(home: home) else {
                return t.fail("the script printed no JSON")
            }
            t.expectEqual(answer["error"] as? String, "not signed in", "error")
            t.expect(answer["hosted"] is [Any], "hosted must be a list: \(answer)")
        },

        // The token must never be an argument: every user of a node can read
        // another's command line.
        TestCase("The node's script hands the token to curl on its input") { t in
            let script = RemoteAllowanceScript.script
            t.expect(script.contains("\"--header\", \"@-\""), "header read from input")
            t.expect(!script.contains("\"Authorization: Bearer \" + token,"), "token on the command line")
        },
    ])
}
