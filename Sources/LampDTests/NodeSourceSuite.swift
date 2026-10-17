import Foundation
import LampBoardCore
import LampDKit
import ProtocolConformance
import TestKit

/// The node as a `v1` source: rows made by the Core's rule for the files, the
/// person's choices, the journal across restarts, and the two ways it serves.
enum NodeSourceSuite {

    static func rows(_ source: NodeSource, at now: Date = F.t0) -> [V1Row] { source.snapshot(at: now).rows ?? [] }

    static let suite = TestSuite("lampd: the node as a source", [

        TestCase("Each row is the probe's row for the same files: one rule, two readers") { t in
            let paths = F.home("rule")
            defer { F.remove(paths) }
            let records = [
                F.record(F.a, pid: 10, status: "busy", tail: F.open, tmux: "api"),
                F.record(F.b, pid: 11, status: "busy", tail: F.ended),
                F.record(F.c, pid: 12, status: "waiting"),
            ]
            let source = F.source(paths)
            source.absorb(F.look(records))
            let probe = V1ProbeSource(identity: F.node, startedAt: F.t0, journal: "probe")
            probe.absorb(F.reading(records), at: F.t0)
            let mine = Dictionary(uniqueKeysWithValues: rows(source).map { ($0.id, $0) })
            for row in probe.snapshot(at: F.t0).rows ?? [] {
                t.expectEqual(mine[row.id]?.session, row.session, "the same lamp for \(row.id.prefix(8))")
                t.expectEqual(mine[row.id]?.extras.stateBasis, .sessionFile, "learned from the file")
                t.expectEqual(mine[row.id]?.extras.terminal, row.extras.terminal, "the same way in")
            }
            t.expectEqual(mine[F.a]?.session.status, "working", "busy, turn open: working")
            t.expectEqual(mine[F.b]?.session.status, "waiting", "busy, turn ended: paused (blue)")
            t.expectEqual(mine[F.c]?.session.status, "awaiting", "waiting: needs you (amber)")
        },

        TestCase("Before the first look the rows are unknown; a failed look keeps them and says why") { t in
            let paths = F.home("unknown")
            defer { F.remove(paths) }
            let source = F.source(paths)
            t.expectNil(source.snapshot(at: F.t0).rows, "null, not an empty column (D21)")
            source.absorb(F.look([F.record(F.a, pid: 10, status: "busy")]))
            let seq = source.status(at: F.t0).seq
            source.absorb(LocalProbe.Look(reading: nil, problem: "the probe exited 1", at: F.t0.addingTimeInterval(5)))
            t.expectEqual(rows(source).count, 1, "the rows stay")
            t.expectEqual(source.status(at: F.t0).seq, seq, "no event")
            t.expectEqual(source.lastProbe.problem, "the probe exited 1", "the reason is kept")
            t.expectEqual(source.status(at: F.t0).lastProbeAt, F.t0.addingTimeInterval(5), "and when it was tried")
        },

        TestCase("The same files again are no event; a change is one; a session gone is one") { t in
            let paths = F.home("events")
            defer { F.remove(paths) }
            let source = F.source(paths)
            source.absorb(F.look([F.record(F.a, pid: 10, status: "busy"), F.record(F.b, pid: 11, status: "idle")]))
            let first = source.status(at: F.t0).seq
            source.absorb(F.look([F.record(F.a, pid: 10, status: "busy"), F.record(F.b, pid: 11, status: "idle")], at: F.t0 + 5))
            t.expectEqual(source.status(at: F.t0).seq, first, "nothing changed, nothing sent")
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle"), F.record(F.b, pid: 11, status: "idle")], at: F.t0 + 10))
            t.expectEqual(source.status(at: F.t0).seq, first + 1, "one change, one event")
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle")], at: F.t0 + 15))
            if case .events(let events) = source.events(after: first + 1) {
                t.expectEqual(events.map(\.change), [.gone(id: F.b)], "the session that went")
            } else { t.expect(false, "the journal reaches back") }
        },

        TestCase("A background session's job says what it did and what `claude attach` takes") { t in
            let paths = F.home("job")
            defer { F.remove(paths) }
            let job = BackgroundJob(id: "job-1", sessionId: F.a, summary: "Ran the migrations", needs: nil)
            let source = F.source(paths)
            source.absorb(F.look([F.record(F.a, pid: 10, status: "busy", kind: "bg")], jobs: [F.a: job]))
            t.expectEqual(rows(source).first?.session.jobId, "job-1", "the id")
            t.expectEqual(rows(source).first?.session.summary, "Ran the migrations", "the summary")
            t.expectEqual(rows(source).first?.session.origin, "background", "a background row")
        },

        TestCase("The person's choices are applied at once, kept on disk, and outlive a restart") { t in
            let paths = F.home("choices")
            defer { F.remove(paths) }
            let peer = V1Peer(device: "phone-1", role: .read)
            let source = F.source(paths)
            source.absorb(F.look([F.record(F.a, pid: 10, status: "busy"), F.record(F.b, pid: 11, status: "idle")]))
            t.expectNil(source.perform(V1Command(action: .rename, session: F.a, name: "Release"), by: peer, at: F.t0), "renamed")
            t.expectNil(source.perform(V1Command(action: .mute, session: F.a, on: true), by: peer, at: F.t0), "muted")
            t.expectNil(source.perform(V1Command(action: .hide, session: F.b, on: true), by: peer, at: F.t0), "hidden")
            t.expectNil(source.perform(V1Command(action: .order, ids: [F.b, F.a]), by: peer, at: F.t0), "ordered")
            t.expectNil(source.perform(V1Command(action: .markSeen, session: F.a), by: peer, at: F.t0), "read")
            let byId = Dictionary(uniqueKeysWithValues: rows(source).map { ($0.id, $0) })
            t.expectEqual(byId[F.a]?.session.label, "Release", "the name")
            t.expectEqual(byId[F.a]?.session.muted, true, "muted")
            t.expectEqual(byId[F.b]?.extras.hidden, true, "hidden")
            t.expectEqual(rows(source).map(\.id), [F.b, F.a], "in the order asked")
            t.expectEqual(byId[F.a]?.extras.readAt, F.t0, "read")
            t.expectEqual(source.perform(V1Command(action: .markSeen, session: F.c), by: peer, at: F.t0)?.code, .notFound,
                          "a row that is not there")

            let again = F.source(paths)
            again.absorb(F.look([F.record(F.a, pid: 10, status: "busy"), F.record(F.b, pid: 11, status: "idle")], at: F.t0 + 5))
            let after = Dictionary(uniqueKeysWithValues: rows(again).map { ($0.id, $0) })
            t.expectEqual(after[F.a]?.session.label, "Release", "the name after a restart")
            t.expectEqual(after[F.b]?.extras.hidden, true, "hidden after a restart")
            t.expectEqual(again.status(at: F.t0).journal, source.status(at: F.t0).journal, "the same journal")
        },

        TestCase("A row taken off stays off until its session speaks again") { t in
            let paths = F.home("dismiss")
            defer { F.remove(paths) }
            let source = F.source(paths)
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle")]))
            t.expectNil(source.perform(V1Command(action: .dismiss, session: F.a), by: V1Peer(device: "p", role: .read),
                                       at: Date(timeIntervalSince1970: 1_800_000_000 + 3600 * 24 * 400)), "taken off")
            t.expectEqual(rows(source).count, 0, "gone")
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle")], at: F.t0 + 5))
            t.expectEqual(rows(source).count, 0, "the same file again does not bring it back")
            let later = #"{"type":"assistant","timestamp":"2029-01-01T00:00:00Z","message":{"model":"claude-opus-4-5","stop_reason":"end_turn","usage":{"input_tokens":1}}}"#
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle", tail: later)], at: F.t0 + 10))
            t.expectEqual(rows(source).count, 1, "a session that speaks after it comes back")
        },

        TestCase("The journal keeps its name and numbers across a restart, and replays exactly what came after") { t in
            let paths = F.home("journal")
            defer { F.remove(paths) }
            let one = F.source(paths)
            one.absorb(F.look([F.record(F.a, pid: 10, status: "busy")]))
            let held = one.status(at: F.t0).seq
            one.absorb(F.look([F.record(F.a, pid: 10, status: "idle")], at: F.t0 + 5))
            let two = F.source(paths)
            t.expectEqual(two.status(at: F.t0).journal, one.status(at: F.t0).journal, "the same journal")
            t.expectEqual(two.status(at: F.t0).seq, held + 1, "the same number")
            if case .events(let events) = two.events(after: held) {
                t.expectEqual(events.map(\.seq), [held + 1], "the event after what the phone held")
            } else { t.expect(false, "replayable") }
        },

        TestCase("A journal whose events outran its rows starts again under another name") { t in
            let paths = F.home("torn")
            defer { F.remove(paths) }
            let one = F.source(paths)
            one.absorb(F.look([F.record(F.a, pid: 10, status: "busy")]))
            let name = one.status(at: F.t0).journal
            // An event the rows never recorded: a run that died between the two.
            let event = V1Event(seq: 99, at: F.t0, change: .gone(id: F.a))
            if let data = try? V1Codec.encoder().encode(event), let handle = FileHandle(forWritingAtPath: paths.journalFile) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data([0x0A]))
                try? handle.close()
            }
            let two = F.source(paths)
            t.expect(two.status(at: F.t0).journal != name, "a new journal: no number is given twice")
            t.expectEqual(two.status(at: F.t0).seq, 0, "numbered from the start")
        },

        TestCase("hello says how the node serves: live from the service, files from a forced command") { t in
            let paths = F.home("mode")
            defer { F.remove(paths) }
            for mode in V1ServingMode.allCases {
                let stream = V1LoopbackStream(source: F.source(paths, mode: mode), peer: V1Peer(device: "p", role: .read),
                                              clock: V1ManualClock(F.t0))
                let hello = try? V1Codec.encode(V1ClientMessage(id: 1, .hello(protocol: 1, client: "test")))
                try? stream.write(V1Frame.encode(hello ?? []))
                var reader = V1FrameReader()
                reader.push((try? stream.read(timeout: 1)) ?? [])
                let frame = (try? reader.next()) ?? nil
                let object = frame.flatMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
                t.expectEqual(object?["mode"] as? String, mode.rawValue, "mode \(mode.rawValue)")
                t.expectEqual(V1WireContract.violations(of: object ?? [:]), [], "within the contract")
            }
        },

        TestCase("A transcript is the conversation's last messages, with how many were not sent") { t in
            let paths = F.home("transcript")
            defer { F.remove(paths) }
            let cwd = "/home/dev/project"
            let folder = paths.claudeDirectory + "/projects/" + TranscriptLocator.directoryName(forWorkspace: cwd)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var lines: [String] = []
            for n in 1...6 {
                lines.append(#"{"type":"user","origin":{"kind":"human"},"timestamp":"2027-01-15T08:0\#(n):00Z","message":{"role":"user","content":"question \#(n) è"}}"#)
                lines.append(#"{"type":"assistant","timestamp":"2027-01-15T08:0\#(n):30Z","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(n)"}]}}"#)
            }
            _ = FileManager.default.createFile(atPath: folder + "/\(F.a).jsonl", contents: Data(lines.joined(separator: "\n").utf8))
            let source = F.source(paths)
            source.absorb(F.look([F.record(F.a, pid: 10, status: "idle", cwd: cwd)]))
            let transcript = source.transcript(session: F.a, limit: 3)
            t.expectEqual(transcript?.messages.map(\.text), ["answer 5", "question 6 è", "answer 6"], "the last three")
            t.expectEqual(transcript?.messages.map(\.role), ["assistant", "user", "assistant"], "who said each")
            t.expectEqual(transcript?.notSent, 9, "and nine before them")
            t.expectNil(source.transcript(session: F.b, limit: 3), "no row, no transcript")
        },

        TestCase("The reading of a transcript does not mangle a character cut between two pieces") { t in
            let paths = F.home("pieces")
            defer { F.remove(paths) }
            let path = paths.home + "/t.jsonl"
            // Padding so that the 'è' of the answer lands across the first megabyte.
            let pad = String(repeating: "x", count: 1_048_576 - 120)
            let lines = [
                #"{"type":"user","timestamp":"2027-01-15T08:00:00Z","message":{"role":"user","content":"\#(pad)"}}"#,
                #"{"type":"assistant","timestamp":"2027-01-15T08:00:30Z","message":{"role":"assistant","content":[{"type":"text","text":"èèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèèè"}]}}"#,
            ]
            _ = FileManager.default.createFile(atPath: path, contents: Data(lines.joined(separator: "\n").utf8))
            let transcript = NodeTranscripts.read(session: F.a, path: path, limit: 1)
            t.expectEqual(transcript?.messages.first?.text, String(repeating: "è", count: 67), "every character whole")
        },
    ])
}

extension Date {
    static func + (date: Date, seconds: TimeInterval) -> Date { date.addingTimeInterval(seconds) }
}
