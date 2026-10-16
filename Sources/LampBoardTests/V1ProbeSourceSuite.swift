import Foundation
import LampBoardCore
import TestKit

/// The lights of a machine that does not serve `v1` yet, read over ssh with the
/// Mac's own probe (D176): the rows it makes, what they say they do not know,
/// their age when the machine falls silent, and the command that reads them,
/// run here against a made-up home to prove it writes nothing.
enum V1ProbeSourceSuite {

    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    static let node = V1SourceIdentity(kind: .node, name: "example-node")
    static let busyId = "11111111-1111-4111-8111-111111111111"
    static let idleId = "22222222-2222-4222-8222-222222222222"

    /// An assistant record as the probe's miniature carries it.
    static let tail = #"{"type":"assistant","timestamp":"2025-10-09T08:00:00Z","message":{"model":"claude-opus-4-5","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":40000}}}"#

    static func record(_ id: String, pid: Int, status: String, tmux: String? = nil, entrypoint: String = "cli",
                       tail: String = tail, cwd: String = "/home/dev/project") -> [String: Any] {
        var record: [String: Any] = [
            "pid": pid, "sessionId": id, "cwd": cwd, "entrypoint": entrypoint, "kind": "interactive",
            "status": status, "activityEpoch": 1_760_000_000, "contextTail": tail,
        ]
        if let tmux { record["tmux"] = ["session": tmux, "window": 0, "pane": 0, "launch": ""] }
        return record
    }

    static func reading(_ records: [[String: Any]], tmux: [TmuxSessionInfo]? = []) -> V1ProbeReading {
        let data = (try? JSONSerialization.data(withJSONObject: ["sessions": records, "windows": []])) ?? Data()
        let report = (try? RemoteSessionsDecoder.report(from: data, host: node.name, at: t0)) ?? .init(sessions: [], windows: [])
        return V1ProbeReading(report: report, tmuxSessions: tmux)
    }

    static func source() -> V1ProbeSource {
        V1ProbeSource(identity: node, startedAt: t0, journal: "probe-1")
    }

    static func rows(_ source: V1ProbeSource, at now: Date = t0) -> [V1Row]? { source.snapshot(at: now).rows }

    static let suite = TestSuite("Lights read over ssh", [

        TestCase("Busy in Claude Code's own file is a working row, otherwise idle; both say the state was read") { t in
            let source = source()
            source.absorb(reading([record(busyId, pid: 10, status: "busy", tmux: "api"), record(idleId, pid: 11, status: "idle")]),
                          at: t0)
            let byId = Dictionary(uniqueKeysWithValues: (rows(source) ?? []).map { ($0.id, $0) })
            t.expectEqual(byId[busyId]?.session.status, "working", "busy is working (D141)")
            t.expectEqual(byId[idleId]?.session.status, "idle", "nothing else is known: idle")
            t.expectEqual(byId[busyId]?.extras.stateBasis, .sessionFile, "the row says how it was learned")
            t.expectEqual(byId[busyId]?.extras.terminal, "tmux:api", "where a terminal can reach it")
            t.expectNil(byId[idleId]?.extras.terminal, "no way in is not invented")
            t.expectEqual(byId[busyId]?.extras.hostReachable, true, "the machine answered")
            t.expectEqual(byId[busyId]?.source, node, "whose row it is")
        },

        TestCase("The context read from the transcript's tail is on the row") { t in
            let source = source()
            source.absorb(reading([record(busyId, pid: 10, status: "busy")]), at: t0)
            let row = rows(source)?.first
            t.expectNotNil(row?.session.contextTokens, "the tokens of the last reply")
            t.expectEqual(row?.session.contextModel, "claude-opus-4-5", "and its model")
        },

        TestCase("Only conversations a person started make rows") { t in
            let source = source()
            source.absorb(reading([
                record(busyId, pid: 10, status: "busy", tail: ""),
                record(idleId, pid: 11, status: "idle", entrypoint: "sdk-ts"),
            ]), at: t0)
            t.expectEqual(rows(source)?.count, 0, "no transcript, and the SDK's, make none")
        },

        TestCase("A change is one event; the same reading again is none") { t in
            let source = source()
            source.absorb(reading([record(busyId, pid: 10, status: "busy")]), at: t0)
            let first = source.status(at: t0).seq
            source.absorb(reading([record(busyId, pid: 10, status: "busy")]), at: t0.addingTimeInterval(20))
            t.expectEqual(source.status(at: t0).seq, first, "nothing changed, nothing sent")
            source.absorb(reading([record(busyId, pid: 10, status: "idle")]), at: t0.addingTimeInterval(40))
            t.expectEqual(source.status(at: t0).seq, first + 1, "one event for the change")
            guard case .events(let events) = source.events(after: first), case .row(let row)? = events.first?.change else {
                t.fail("no row event"); return
            }
            t.expectEqual(row.session.status, "idle", "the whole row, now idle")
        },

        TestCase("A session that ended is a row gone") { t in
            let source = source()
            source.absorb(reading([record(busyId, pid: 10, status: "busy"), record(idleId, pid: 11, status: "idle")]), at: t0)
            let before = source.status(at: t0).seq
            source.absorb(reading([record(idleId, pid: 11, status: "idle")]), at: t0.addingTimeInterval(20))
            guard case .events(let events) = source.events(after: before) else { t.fail("no events"); return }
            t.expectEqual(events.map(\.change), [.gone(id: busyId)], "one row gone")
        },

        TestCase("A machine that does not answer keeps its rows, said unreachable, with the age of its last answer") { t in
            let source = source()
            source.absorb(reading([record(busyId, pid: 10, status: "busy")]), at: t0)
            let later = t0.addingTimeInterval(120)
            source.absorb(nil, at: later)
            let row = rows(source, at: later)?.first
            t.expectEqual(row?.session.status, "working", "the last state, not a guess")
            t.expectEqual(row?.extras.hostReachable, false, "said unreachable")
            t.expectEqual(row?.extras.hostProbedAt, t0, "with the time of the last answer")
            t.expectEqual(source.snapshot(at: later).rowsAt, t0, "the rows are as old as that answer")
            t.expectEqual(source.status(at: later).lastProbeAt, t0, "and so is the state's age in hello")
            t.expectEqual(source.answeredAt, t0, "the reading's age, for the app")
            let seq = source.status(at: later).seq
            source.absorb(nil, at: later.addingTimeInterval(20))
            t.expectEqual(source.status(at: later).seq, seq, "a second silence sends nothing more")
            source.absorb(reading([record(busyId, pid: 10, status: "busy")]), at: later.addingTimeInterval(40))
            t.expectEqual(rows(source)?.first?.extras.hostReachable, true, "an answer brings it back")
        },

        TestCase("Before any answer the rows are unknown; an empty answer is an empty column") { t in
            let source = source()
            t.expectNil(rows(source), "never known is null, not []")
            source.absorb(nil, at: t0)
            t.expectNil(rows(source), "no answer is still null")
            source.absorb(reading([]), at: t0)
            t.expectEqual(rows(source)?.count, 0, "asked, and nothing runs")
        },

        TestCase("What the person chose stays through every reading") { t in
            let source = source()
            source.absorb(reading([record(busyId, pid: 10, status: "busy")]), at: t0)
            let peer = V1Peer(device: "phone-1", role: .read)
            _ = source.perform(V1Command(action: .hide, session: busyId, on: true), by: peer, at: t0)
            _ = source.perform(V1Command(action: .rename, session: busyId, name: "Example name"), by: peer, at: t0)
            _ = source.perform(V1Command(action: .markSeen, session: busyId), by: peer, at: t0)
            source.absorb(reading([record(busyId, pid: 10, status: "idle")]), at: t0.addingTimeInterval(20))
            let row = rows(source)?.first
            t.expectEqual(row?.session.status, "idle", "the reading moved on")
            t.expectEqual(row?.extras.hidden, true, "hidden stays hidden")
            t.expectEqual(row?.session.label, "Example name", "the name stays")
            t.expectNotNil(row?.extras.readAt, "read stays read")
        },

        TestCase("The answer is the probe and tmux's sessions; garbage is no answer, not an empty machine") { t in
            let probe = #"{"sessions":[],"windows":[]}"#
            let output = probe + "\n" + V1ProbeReading.separator + "\n"
                + "1\t2\t1760000000\t1759990000\tapi\n0\t1\t1760000100\t1759990100\tit's a name\nbroken\n"
            let parsed = V1ProbeReading.parse(output, host: node.name, at: t0)
            t.expectEqual(parsed?.report.sessions.count, 0, "the probe's part")
            t.expectEqual(parsed?.tmuxSessions?.map(\.name), ["api", "it's a name"], "tmux's part, a broken line skipped")
            t.expectEqual(parsed?.tmuxSessions?.first?.attachedClients, 1, "how many clients")
            t.expectEqual(parsed?.tmuxSessions?.first?.windows, 2, "and windows")
            let noTmux = V1ProbeReading.parse(probe + "\n" + V1ProbeReading.separator + "\n" + V1ProbeReading.noTmux + "\n",
                                              host: node.name, at: t0)
            t.expectNil(noTmux?.tmuxSessions ?? nil, "a machine without tmux has no sessions to list, which is not zero")
            t.expectNotNil(noTmux, "but did answer")
            t.expectNil(V1ProbeReading.parse("python3: not found\n" + V1ProbeReading.separator + "\n", host: node.name, at: t0),
                        "no probe output is no answer")
            t.expectNil(V1ProbeReading.parse(probe, host: node.name, at: t0), "a cut answer is no answer")
        },

        TestCase("The command reads a home and writes nothing in it") { t in
            guard let home = makeHome() else { t.fail("could not make the example home"); return }
            defer { try? FileManager.default.removeItem(atPath: home) }
            let before = listing(home)
            guard let output = runLocally(V1ProbeReading.command(), home: home) else { t.fail("did not run"); return }
            let parsed = V1ProbeReading.parse(output, host: node.name, at: Date())
            t.expectEqual(parsed?.report.sessions.map(\.sessionId), [busyId], "the live session in the example home: \(output.prefix(160))")
            t.expectEqual(parsed?.tmuxSessions?.map(\.name), ["example"], "tmux's sessions, through the stand-in")
            t.expectEqual(listing(home), before, "not one file created, changed or removed")
        },

        // MARK: When a session last spoke, read where it runs

        // Reported from the first build on a phone: sessions of a project quiet
        // for a day and a half read "last heard 13m ago", and never folded into
        // Resting, because the probe took the newest file of the whole project
        // folder. Another conversation there, or bookkeeping appended to the
        // session's own file, moved every row of the project.
        TestCase("A session's time is its own transcript's last spoken moment, not its project's newest file") { t in
            let spoke = "2025-10-01T08:00:00Z"
            let own = #"{"type":"assistant","timestamp":"\#(spoke)","message":{"role":"assistant"}}"#
                + "\n" + #"{"type":"last-prompt"}"#
            guard let session = probedSession(own: own) else { t.fail("the probe did not run"); return }
            t.expectEqual(session.modifiedAt, ISO8601DateFormatter().date(from: spoke),
                          "a session's time is when it last spoke, not its project's newest file")
        },

        TestCase("With nothing timestamped in its tail, the session's own file dates it, never a neighbour's") { t in
            let fileDate = Date(timeIntervalSince1970: 1_759_400_000)
            guard let session = probedSession(own: #"{"type":"last-prompt"}"#, ownDate: fileDate,
                                              sessionFileDate: fileDate.addingTimeInterval(-3_600)) else {
                t.fail("the probe did not run"); return
            }
            t.expectEqual(session.modifiedAt, fileDate,
                          "a session with no spoken moment is dated by its own file, never a neighbour's")
        },

        TestCase("A session in a git worktree finds its transcript by its id, and keeps its time") { t in
            let spoke = "2025-10-02T09:30:00Z"
            let own = #"{"type":"assistant","timestamp":"\#(spoke)","message":{"role":"assistant"}}"#
            guard let session = probedSession(own: own, ownFolder: "-home-dev-project--worktrees-feature") else {
                t.fail("the probe did not run"); return
            }
            t.expectEqual(session.hasTranscript, true, "the transcript filed under the worktree is found")
            t.expectEqual(session.modifiedAt, ISO8601DateFormatter().date(from: spoke), "and its time read")
        },

        TestCase("The decoder dates a session by the last timestamp of the tail it was sent") { t in
            let tail = #"{"type":"assistant","timestamp":"2025-10-01T08:00:00Z"}"# + "\n" + #"{"type":"last-prompt","timestamp":null}"#
            let sessions = reading([record(idleId, pid: 11, status: "idle", tail: tail)]).report.sessions
            t.expectEqual(sessions.first?.modifiedAt, ISO8601DateFormatter().date(from: "2025-10-01T08:00:00Z"),
                          "the tail's last spoken moment wins over the files' dates")
            let untimed = reading([record(idleId, pid: 11, status: "idle", tail: #"{"type":"last-prompt"}"#)]).report.sessions
            t.expectEqual(untimed.first?.modifiedAt, Date(timeIntervalSince1970: 1_760_000_000),
                          "nothing timed in the tail: the files' date the probe sent")
        },
    ])

    /// The one session the probe reports from a home where it has two
    /// conversations in one project: its own (`own`, in `ownFolder` when given,
    /// dated `ownDate` when given) and a neighbour's, written now.
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
            try #"{"pid":\#(pid),"sessionId":"\#(idleId)","cwd":"\#(cwd)","entrypoint":"cli","kind":"interactive","status":"idle"}"#
                .write(toFile: sessionFile, atomically: true, encoding: .utf8)
            let ownPath = "\(home)/.claude/projects/\(ownFolder ?? encoded)/\(idleId).jsonl"
            try (own + "\n").write(toFile: ownPath, atomically: true, encoding: .utf8)
            let neighbour = #"{"type":"assistant","timestamp":"2026-10-16T08:00:00Z","message":{"role":"assistant"}}"#
            try (neighbour + "\n").write(toFile: "\(home)/.claude/projects/\(encoded)/\(busyId).jsonl",
                                         atomically: true, encoding: .utf8)
            if let ownDate { try fm.setAttributes([.modificationDate: ownDate], ofItemAtPath: ownPath) }
            if let sessionFileDate { try fm.setAttributes([.modificationDate: sessionFileDate], ofItemAtPath: sessionFile) }
            try "#!/bin/sh\nexit 0\n".write(toFile: "\(home)/bin/tmux", atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(home)/bin/tmux")
        } catch {
            return nil
        }
        guard let output = runLocally(V1ProbeReading.command(), home: home) else { return nil }
        return V1ProbeReading.parse(output, host: node.name, at: Date())?.report.sessions.first
    }

    // MARK: - An example home, run under /bin/sh

    /// A home with one live session (this process: alive for as long as the
    /// test runs) and its transcript, and a `tmux` stand-in on the PATH.
    static func makeHome() -> String? {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lbtest-probe-\(UUID().uuidString)").path
        let cwd = "/home/dev/project"
        let encoded = "-" + String(cwd.dropFirst().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            let fm = FileManager.default
            try fm.createDirectory(atPath: "\(home)/.claude/sessions", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(home)/.claude/projects/\(encoded)", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(home)/bin", withIntermediateDirectories: true)
            let session = #"{"pid":\#(pid),"sessionId":"\#(busyId)","cwd":"\#(cwd)","entrypoint":"cli","kind":"interactive","status":"busy"}"#
            try session.write(toFile: "\(home)/.claude/sessions/\(pid).json", atomically: true, encoding: .utf8)
            try (tail + "\n").write(toFile: "\(home)/.claude/projects/\(encoded)/\(busyId).jsonl", atomically: true, encoding: .utf8)
            let tmux = "#!/bin/sh\ncase \"$*\" in *list-sessions*) printf '1\\t1\\t1760000000\\t1759990000\\texample\\n' ;; esac\nexit 0\n"
            try tmux.write(toFile: "\(home)/bin/tmux", atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(home)/bin/tmux")
        } catch {
            return nil
        }
        return home
    }

    /// Every file under `root` with its size and modification time.
    static func listing(_ root: String) -> [String] {
        let fm = FileManager.default
        return (fm.subpaths(atPath: root) ?? []).sorted().map { path in
            let attributes = (try? fm.attributesOfItem(atPath: "\(root)/\(path)")) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let time = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(path) \(size) \(time)"
        }
    }

    static func runLocally(_ command: String, home: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "\(home)/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": home]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
