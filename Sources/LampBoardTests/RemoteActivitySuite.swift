import LampBoardCore
import Foundation
import TestKit

/// When a session on another machine last spoke.
///
/// Reported on 2.3.0, 17 October: five sessions on the always-on machine,
/// untouched for days, read "10h" on the Mac. Their transcripts had last spoken
/// between the 11th and the 15th, but Claude Code appends records with no
/// timestamp to every open session (`frame-link`, `custom-title`, `mode`…), so
/// each file's date was that morning's. The probe dated a session by the newest
/// file of its whole project folder, and the Mac adopted the rows with that date.
/// The same rule the Mac applies to its own transcripts (`TranscriptActivity`)
/// now dates them: the last timestamped record of the session's own tail.
enum RemoteActivitySuite {

    static let ownId = "22222222-2222-4222-8222-222222222222"
    static let neighbourId = "11111111-1111-4111-8111-111111111111"

    static let suite = TestSuite("When a session on another machine last spoke", [

        TestCase("A session's time is its own transcript's last spoken moment, not its project's newest file") { t in
            let spoke = "2025-10-01T08:00:00Z"
            let own = #"{"type":"assistant","timestamp":"\#(spoke)","message":{"role":"assistant"}}"#
                + "\n" + #"{"type":"frame-link"}"# + "\n" + #"{"type":"custom-title","customTitle":"x"}"#
            guard let session = probedSession(own: own) else { return t.fail("the probe did not run") }
            t.expectEqual(session.modifiedAt, ISO8601DateFormatter().date(from: spoke),
                          "a session's time is when it last spoke, not its project's newest file")
        },

        TestCase("With nothing timestamped in its tail, the session's own file dates it, never a neighbour's") { t in
            let fileDate = Date(timeIntervalSince1970: 1_759_400_000)
            guard let session = probedSession(own: #"{"type":"last-prompt"}"#, ownDate: fileDate,
                                              sessionFileDate: fileDate.addingTimeInterval(-3_600)) else {
                return t.fail("the probe did not run")
            }
            t.expectEqual(session.modifiedAt, fileDate,
                          "a session with no spoken moment is dated by its own file, never a neighbour's")
        },

        TestCase("A session in a git worktree finds its transcript by its id, and keeps its time") { t in
            let spoke = "2025-10-02T09:30:00Z"
            let own = #"{"type":"assistant","timestamp":"\#(spoke)","message":{"role":"assistant"}}"#
            guard let session = probedSession(own: own, ownFolder: "-home-dev-project--worktrees-feature") else {
                return t.fail("the probe did not run")
            }
            t.expectEqual(session.hasTranscript, true, "the transcript filed under the worktree is found")
            t.expectEqual(session.modifiedAt, ISO8601DateFormatter().date(from: spoke), "and its time read")
        },

        TestCase("The decoder dates a session by the last timestamp of the tail it was sent") { t in
            func decoded(_ tail: String) -> LiveSession? {
                let object: [String: Any] = [
                    "pid": 11, "sessionId": ownId, "cwd": "/home/dev/project", "activityEpoch": 1_760_000_000,
                    "status": "idle", "contextTail": tail,
                ]
                let data = (try? JSONSerialization.data(withJSONObject: [object])) ?? Data()
                return (try? RemoteSessionsDecoder.decode(data, host: "node"))?.first
            }
            let tail = #"{"type":"assistant","timestamp":"2025-10-01T08:00:00Z"}"# + "\n" + #"{"type":"last-prompt","timestamp":null}"#
            t.expectEqual(decoded(tail)?.modifiedAt, ISO8601DateFormatter().date(from: "2025-10-01T08:00:00Z"),
                          "the tail's last spoken moment wins over the files' dates")
            t.expectEqual(decoded(#"{"type":"last-prompt"}"#)?.modifiedAt, Date(timeIntervalSince1970: 1_760_000_000),
                          "nothing timed in the tail: the files' date the probe sent")
        },
    ])

    /// The one session the probe reports from a home where its project holds
    /// two conversations: its own (`own`, in `ownFolder` when given, dated
    /// `ownDate` when given) and a neighbour's, written now. The probe runs for
    /// real, under `python3`, as it runs on the other machine.
    static func probedSession(own: String, ownFolder: String? = nil, ownDate: Date? = nil,
                              sessionFileDate: Date? = nil) -> LiveSession? {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lbtest-activity-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = "/home/dev/project"
        let encoded = "-" + String(cwd.dropFirst().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let pid = ProcessInfo.processInfo.processIdentifier
        let fm = FileManager.default
        do {
            for folder in [".claude/sessions", ".claude/projects/\(encoded)", ".claude/projects/\(ownFolder ?? encoded)", "bin"] {
                try fm.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
            }
            let sessionFile = "\(home)/.claude/sessions/\(pid).json"
            try #"{"pid":\#(pid),"sessionId":"\#(ownId)","cwd":"\#(cwd)","entrypoint":"cli","kind":"interactive","status":"idle"}"#
                .write(toFile: sessionFile, atomically: true, encoding: .utf8)
            let ownPath = "\(home)/.claude/projects/\(ownFolder ?? encoded)/\(ownId).jsonl"
            try (own + "\n").write(toFile: ownPath, atomically: true, encoding: .utf8)
            let neighbour = #"{"type":"assistant","timestamp":"2026-10-16T08:00:00Z","message":{"role":"assistant"}}"#
            try (neighbour + "\n").write(toFile: "\(home)/.claude/projects/\(encoded)/\(neighbourId).jsonl",
                                         atomically: true, encoding: .utf8)
            if let ownDate { try fm.setAttributes([.modificationDate: ownDate], ofItemAtPath: ownPath) }
            if let sessionFileDate { try fm.setAttributes([.modificationDate: sessionFileDate], ofItemAtPath: sessionFile) }
            try "#!/bin/sh\nexit 0\n".write(toFile: "\(home)/bin/tmux", atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(home)/bin/tmux")
        } catch {
            return nil
        }
        guard let output = runProbe(home: home) else { return nil }
        return (try? RemoteSessionsDecoder.report(from: Data(output.utf8), host: "node", at: Date()))?.sessions.first
    }

    /// The probe piped to `python3`, as `RemoteSessionReader` pipes it over ssh,
    /// with `home` as its home.
    static func runProbe(home: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-"]
        process.environment = ["PATH": "\(home)/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(RemoteProbeScript.script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
