import LampBoardCore
import Foundation
import TestKit

/// A 429 slows the strip down and leaves what it knew on screen.
enum AllowanceThrottleSuite {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func report(_ email: String?, _ uuid: String?, machine: String = "this Mac", age: TimeInterval) -> AllowanceReport {
        AllowanceReport(
            account: (email == nil && uuid == nil) ? nil : ClaudeAccount(email: email, uuid: uuid),
            machine: machine,
            limits: AccountLimits(
                limits: [AccountLimits.Limit(span: .session, percent: 10, resetsAt: nil)],
                readAt: now.addingTimeInterval(-age)
            )
        )
    }

    static let suite = TestSuite("Asked too often", [

        TestCase("No refusal keeps the ordinary interval") { t in
            t.expectEqual(AllowanceThrottle.interval(afterRefusals: 0, base: 150), 150)
        },

        TestCase("Each refusal doubles the wait, up to the ceiling") { t in
            t.expectEqual(AllowanceThrottle.interval(afterRefusals: 1, base: 150), 300)
            t.expectEqual(AllowanceThrottle.interval(afterRefusals: 2, base: 150), 600)
            t.expectEqual(AllowanceThrottle.interval(afterRefusals: 9, base: 150), AllowanceThrottle.ceiling)
            t.expectEqual(AllowanceThrottle.interval(afterRefusals: 500, base: 150), AllowanceThrottle.ceiling)
        },

        // The failure this exists for: a refused round emptied the strip.
        TestCase("A refused account keeps its last reading, with its own age") { t in
            let old = report("design@example.com", "u-1", age: 120)
            let kept = AllowanceThrottle.carriedOver(previous: [old], fresh: [], now: now)
            t.expectEqual(kept.count, 1, "kept")
            t.expectEqual(kept.first?.limits.readAt, old.limits.readAt, "never restamped")
        },

        TestCase("A fresh reading replaces the old one of the same account") { t in
            let old = report("design@example.com", "u-1", age: 120)
            let new = report("design@example.com", "u-1", age: 0)
            let kept = AllowanceThrottle.carriedOver(previous: [old], fresh: [new], now: now)
            t.expectEqual(kept.map(\.limits.readAt), [new.limits.readAt], "only the fresh one")
        },

        TestCase("The other accounts still come back beside a fresh one") { t in
            let kept = AllowanceThrottle.carriedOver(
                previous: [report("design@example.com", "u-1", age: 120)],
                fresh: [report("sam@example.net", "u-2", machine: "node", age: 0)],
                now: now
            )
            t.expectEqual(kept.map(\.label), ["sam@example.net", "design@example.com"], "labels")
        },

        TestCase("A reading older than the limit is history and is dropped") { t in
            let kept = AllowanceThrottle.carriedOver(
                previous: [report("design@example.com", "u-1", age: AllowanceThrottle.keepFor + 1)],
                fresh: [], now: now
            )
            t.expectEqual(kept.count, 0, "kept")
        },

        TestCase("An unnamed reading is carried only when its machine said nothing new") { t in
            let old = report(nil, nil, machine: "node", age: 60)
            t.expectEqual(
                AllowanceThrottle.carriedOver(previous: [old], fresh: [report(nil, nil, machine: "node", age: 0)], now: now).count,
                1, "replaced by the fresh one"
            )
            t.expectEqual(AllowanceThrottle.carriedOver(previous: [old], fresh: [], now: now).count, 1, "carried")
        },

        // Executed: the node skips its own account when the caller already has it,
        // and does not ask — a fake token would otherwise come back as an error.
        TestCase("The node's script skips an account the caller already asked about") { t in
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("lampboard-skip-\(UUID().uuidString)")
            let claude = home.appendingPathComponent(".claude")
            defer { try? FileManager.default.removeItem(at: home) }
            do {
                try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
                try Data(#"{"oauthAccount": {"emailAddress": "sam@example.net", "accountUuid": "u-2"}}"#.utf8)
                    .write(to: home.appendingPathComponent(".claude.json"))
                try Data(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-fake"}}"#.utf8)
                    .write(to: claude.appendingPathComponent(".credentials.json"))
            } catch {
                return t.fail("could not build the fixture: \(error)")
            }
            guard let answer = PythonRunner.object(RemoteAllowanceScript.script(skipping: ["u-2"]), home: home) else {
                return t.fail("the script printed no JSON")
            }
            t.expectEqual(answer["skipped"] as? Bool, true, "skipped")
            t.expectNil(answer["error"], "no ask, so no error")
            t.expectNil(answer["throttled"], "throttled")
        },

        // The list is pasted into the program, so it must not be able to say
        // anything but uuids.
        TestCase("Nothing but a uuid's characters reaches the node's program") { t in
            let script = RemoteAllowanceScript.script(skipping: ["u-1\"]); import os #", "abc-123"])
            t.expect(script.contains("asked = set([\"u-1importos\", \"abc-123\"])"), "sanitised list")
            t.expect(!script.contains("; import os"), "injected code")
        },
    ])
}

/// Runs a Python program the way the ssh wrapper does: on standard input, with
/// the home the test chose.
enum PythonRunner {
    static func object(_ script: String, home: URL) -> [String: Any]? {
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
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
