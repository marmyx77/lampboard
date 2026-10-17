import Foundation
import LampBoardCore

/// This machine's allowance (`lampd usage`): the Core's script the Mac already
/// runs here over ssh (`RemoteAllowanceScript`), run here directly. The token
/// stays where Claude Code keeps it and reaches curl on its standard input; what
/// comes back is three percentages per account.
public enum LampDUsage {

    public struct Reading: Sendable {
        public let reports: [AllowanceReport]
        public let problem: String?
        public let throttled: Bool
        public let at: Date
    }

    public static func read(paths: LampDPaths, name: String, at now: Date = Date()) -> Reading {
        do {
            let result = try Command.run(
                "/usr/bin/env", ["python3", "-B", "-c", RemoteAllowanceScript.script(skipping: [])],
                deadline: 45, capturingStandardError: false, environment: ["HOME": paths.home]
            )
            guard let object = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any] else {
                return Reading(reports: [], problem: "the allowance script's answer could not be read (exit \(result.status))",
                               throttled: false, at: now)
            }
            let reports = RemoteAllowanceScript.reports(in: object, host: name, readAt: now)
            let problem = object["error"] as? String
            return Reading(reports: reports, problem: reports.isEmpty ? (problem ?? "no figures") : nil,
                           throttled: object["throttled"] as? Bool == true, at: now)
        } catch let failure as Command.Failure {
            return Reading(reports: [], problem: failure.explanation, throttled: false, at: now)
        } catch {
            return Reading(reports: [], problem: "\(error)", throttled: false, at: now)
        }
    }

    /// The lines `lampd usage` prints.
    public static func lines(_ reading: Reading, at now: Date = Date()) -> [String] {
        var out: [String] = []
        for report in reading.reports {
            out.append("\(report.label)")
            for limit in report.limits.limits {
                let reset = limit.resetsAt.map { resetsAt -> String in
                    let remaining = resetsAt.timeIntervalSince(now)
                    return remaining > 0 ? "resets in \(ShortSpan.label(seconds: remaining))" : "resetting"
                } ?? "no reset"
                out.append("  " + limit.label.padding(toLength: 12, withPad: " ", startingAt: 0)
                           + String(limit.percent).padding(toLength: 4, withPad: " ", startingAt: 0) + "%  " + reset)
            }
        }
        if let problem = reading.problem { out.append(problem) }
        if reading.throttled { out.append("the usage service answered 429 to one of the tokens") }
        return out
    }

    /// Writes a reading where `lampd usage --cached` and the phone (W3b) find it.
    public static func save(_ reading: Reading, to path: String) {
        let object: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: reading.at),
            "lines": lines(reading, at: reading.at),
            "problem": reading.problem ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? AtomicFile.write(data, to: path)
    }

    /// The service's own refresher, only when the configuration turns it on: one
    /// reading every `interval`, on a thread of its own and never on the main
    /// loop, which the watchdog times.
    public static func refresh(paths: LampDPaths, name: String, every interval: TimeInterval = AppConfig.usagePollInterval) {
        Thread.detachNewThread {
            while true {
                save(read(paths: paths, name: name), to: paths.allowanceFile)
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }
}
