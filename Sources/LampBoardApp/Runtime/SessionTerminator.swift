import Foundation
import LampBoardCore

/// Finds the process behind a row, and ends it when asked.
///
/// In the shell because it reads a directory and signals a process. The rules it
/// obeys are all about not ending the wrong thing:
///
/// - only a session that names its process in `~/.claude/sessions`, which is
///   Claude Code and nothing else;
/// - only if that process is alive **and** started when the file says, because
///   process ids are reused and the files outlive what they describe;
/// - `SIGTERM`, never `SIGKILL`: the session is asked to end, and gets to write
///   what it was holding.
enum SessionTerminator {

    private static var directory: URL {
        AppConfig.homeDirectory.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// The process running this session, or `nil` when there is nothing safe to end.
    ///
    /// `nil` covers every uncertainty on purpose: no file, a file that does not
    /// parse, a process that has gone, or one whose start time disagrees with the
    /// record. The caller shows no menu entry in any of those cases, which is the
    /// honest thing to do — an entry that might end something else is worse than
    /// no entry.
    static func process(of sessionId: String) -> SessionProcess? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let candidate = SessionProcess.from(json: data),
                  candidate.sessionId == sessionId
            else { continue }
            guard isAlive(candidate.pid), let started = startTime(of: candidate.pid),
                  candidate.isStill(startedAt: started)
            else { return nil }
            return candidate
        }
        return nil
    }

    /// Asks the process to end. Returns whether the signal was delivered.
    ///
    /// Everything is checked again here rather than trusted from the menu: the
    /// process may have ended between the click and the confirmation, and a pid
    /// that has been reused in those seconds must not be signalled.
    static func terminate(_ process: SessionProcess) -> Bool {
        guard isAlive(process.pid), let started = startTime(of: process.pid),
              process.isStill(startedAt: started)
        else { return false }
        return kill(process.pid, SIGTERM) == 0
    }

    /// Whether the process is still the one the session file named: alive,
    /// and started when it says. A pid reused since is not it.
    static func isStillRunning(_ process: SessionProcess) -> Bool {
        guard isAlive(process.pid), let started = startTime(of: process.pid) else { return false }
        return process.isStill(startedAt: started)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// What the system says about when a process started, in `ps` form.
    ///
    /// Asked in **UTC**, because the session file records the start in UTC and
    /// `ps` answers in local time. Measured here: every pair differed by exactly
    /// the offset of the zone — two hours — so a comparison of the two strings
    /// never matched, and the menu entry that depends on it would have been
    /// invisible for ever. A safety check that can only fail is not a safety
    /// check, it is a feature that does not exist.
    private static func startTime(of pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "lstart=", "-p", String(pid)]
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = "UTC"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}
