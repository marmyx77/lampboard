import LampBoardCore
import Foundation
import TestKit

/// `lampboard watch` run for real against the panel (D70).
enum WatchE2ESuite {

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · lampboard watch", [

            TestCase("a failing command becomes a red row, and its exit code is the command's") { a in
                let result = app.runCommand(["watch", "--port", String(app.port), "--name", "e2e-failing",
                                             "--", "/bin/sh", "-c", "echo working; exit 3"])
                a.expectEqual(result.status, 3, "the command's own exit code")
                a.expect(result.output.contains("working"), "the command's own output: \(result.output)")
                let row = app.sessions()?.sessions.first { $0.title == "e2e-failing" }
                a.expectEqual(row?.status, "failed")
                a.expectEqual(row?.harness, "command")
                a.expectEqual(row?.lastMessage?.hasPrefix("exited with 3"), true)
            },

            TestCase("a command that succeeds becomes green; its own --port is its own") { a in
                let result = app.runCommand(["watch", "--port", String(app.port), "--name", "e2e-green",
                                             "--", "/bin/sh", "-c", "exit 0", "--port", "1"])
                a.expectEqual(result.status, 0)
                a.expectEqual(app.sessions()?.sessions.first { $0.title == "e2e-green" }?.status, "ready")
                // No --name: the program's name, never its arguments, which can carry a password.
                _ = app.runCommand(["watch", "--port", String(app.port), "--", "/usr/bin/true", "--password", "hunter2"])
                let named = app.sessions()?.sessions.filter { $0.harness == "command" }.map { $0.title ?? "" } ?? []
                a.expect(named.contains("true"), "named after the program: \(named)")
                a.expect(!named.contains { $0.contains("hunter2") }, "no argument in a name")
            },

            TestCase("/watch needs the token, and a panel that is not there leaves the command alone") { a in
                let body = #"{"v":1,"id":"e2e0e2e0e2e0","name":"x","cwd":"/tmp","phase":"start"}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.watchPath, token: .some(nil), body: body).status, 401)
                let file = #"{"v":1,"id":"e2e0e2e0e2e1","name":"x","cwd":"/bin/sh","phase":"start"}"#
                a.expectEqual(app.raw(method: "POST", path: AppConfig.watchPath, body: file).status, 400,
                              "a folder that is a file: the row's folder glyph would open it")
                let alone = app.runCommand(["watch", "--port", "9", "--", "/bin/sh", "-c", "exit 4"])
                a.expectEqual(alone.status, 4, "run anyway, exit code kept")
                a.expect(alone.output.contains("did not hear"), "said once: \(alone.output)")
            },
        ])
    }
}
