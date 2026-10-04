import LampBoardCore
import Foundation
import TestKit

/// A session file whose pid now belongs to another process is a dead session.
///
/// The live process is a `sleep` started here, so the case controls its start:
/// the file names it with the start `ps` gives (in UTC, as Claude Code writes
/// it on macOS) or with one an hour earlier, which is a recycled pid.
enum PidReuseE2ESuite {

    static let reused = "e2e9e1d0-0000-4000-8000-00000000dead"
    static let genuine = "e2e9e1d0-0000-4000-8000-00000000a11e"

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · recycled pids", [

            TestCase("a pid that now belongs to another process makes no row; the right start does") { a in
                let sleeper = Process()
                sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
                sleeper.arguments = ["60"]
                guard (try? sleeper.run()) != nil else { return a.fail("sleep did not start") }
                defer { sleeper.terminate() }
                guard let started = startOf(sleeper.processIdentifier) else { return a.fail("ps gave no start") }

                // A conversation behind each, or neither would be adopted and the
                // first check would pass for the wrong reason.
                app.writeTranscript(sessionId: reused, cwd: LifecycleSuite.workspace, title: "Recycled")
                app.writeTranscript(sessionId: genuine, cwd: LifecycleSuite.workspace, title: "Genuine")
                let earlier = shifted(started, by: -3600)
                app.writeLiveSession(sessionId: reused, cwd: LifecycleSuite.workspace,
                                     pid: sleeper.processIdentifier, procStart: earlier)
                // Given the time two realignments take, it must still be absent.
                Thread.sleep(forTimeInterval: AppConfig.liveSessionPollInterval * 2 + 1)
                a.expectEqual(app.status(of: reused), "absent", "a dead session's pid, held by a stranger")

                app.writeLiveSession(sessionId: genuine, cwd: LifecycleSuite.workspace,
                                     pid: sleeper.processIdentifier, procStart: started)
                a.expect(app.waitUntil { app.status(of: genuine) != "absent" },
                         "the file naming the process's own start is a live session")
            },
        ])
    }

    /// `lstart` in UTC: the form Claude Code writes into the session file.
    private static func startOf(_ pid: Int32) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(pid)]
        ps.environment = ["TZ": "UTC"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func shifted(_ ctime: String, by seconds: TimeInterval) -> String {
        guard case .date(let date)? = ProcStart.parse(ctime) else { return ctime }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date.addingTimeInterval(seconds))
    }
}
