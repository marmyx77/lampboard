import LampBoardCore
import Foundation
import TestKit

/// The tutorial's trial in the real binary: the invented sessions reach their
/// colours through the server and the reducer, and quitting leaves nothing.
enum TrialE2ESuite {

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        TestSuite("E2E · tutorial trial", [

            TestCase("the trial plays the script into the panel's real states") { t in
                let trial = AppUnderTest(binaryURL: binaryURL, port: port)
                trial.extraArguments = ["--trial", "--trial-pace", "20"]
                defer { trial.stop() }
                do { try trial.start() } catch { return t.fail("the trial did not start: \(error)") }
                let expected = ["demo-docs-0001": "ready", "demo-api-00002": "awaiting",
                                "demo-events-03": "working", "demo-mobile-04": "failed",
                                "demo-search-05": "waiting", "demo-billing-6": "idle"]
                let reached = trial.waitUntil(timeout: 15) {
                    expected.allSatisfy { trial.status(of: $0.key) == $0.value }
                }
                t.expect(reached, "every session in its scripted state: \(expected.keys.sorted().map { "\($0)=\(trial.status(of: $0))" })")
                let state = trial.raw(method: "GET", path: AppConfig.lampMasterPath)
                t.expect(state.body.contains("demo slots renamed"), "LampMaster's demo card is there")
            },

            TestCase("quitting a trial removes its home and its stand-in processes") { t in
                let home = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lampboard-trial-e2e\(ProcessInfo.processInfo.processIdentifier)")
                let trial = AppUnderTest(binaryURL: binaryURL, port: port, home: home)
                trial.extraArguments = ["--trial", "--trial-pace", "20"]
                do { try trial.start() } catch { return t.fail("the trial did not start: \(error)") }
                let sessions = home.appendingPathComponent(".claude/sessions")
                let holders = ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [])
                    .compactMap { Int32($0.replacingOccurrences(of: ".json", with: "")) }
                t.expectEqual(holders.count, 6, "one stand-in per session")
                trial.stopKeepingHome()
                let gone = trial.waitUntil(timeout: 5) { !FileManager.default.fileExists(atPath: home.path) }
                t.expect(gone, "the trial's home is deleted")
                t.expect(holders.allSatisfy { kill($0, 0) != 0 }, "no stand-in left running")
                try? FileManager.default.removeItem(at: home)
            },

            TestCase("tour --json prints the script, and it holds nothing real") { t in
                let trial = AppUnderTest(binaryURL: binaryURL, port: port)
                let printed = trial.runCommand(["tour", "--json"])
                t.expectEqual(printed.status, 0)
                let script = try? JSONDecoder().decode(DemoScript.self, from: Data(printed.output.utf8))
                t.expectEqual(script?.sessions.count, 6, "the six invented sessions")
                t.expectEqual(script.map(DemoScriptCheck.problems), [], "nothing real")
            },
        ])
    }
}
