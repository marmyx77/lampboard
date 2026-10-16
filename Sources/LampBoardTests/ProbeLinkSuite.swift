import Foundation
import LampBoardCore
import LampBoardNodeLink
import TestKit

/// The lights of a machine without `v1`, read on a clock and served to the
/// app's `V1Link` from memory (D176), with a made-up machine behind `run`. The
/// same over a real ssh is `Scripts/test-nodelink.sh`.
enum ProbeLinkSuite {

    static let node = V1SourceIdentity(kind: .node, name: "example-node")
    static let sid = "33333333-3333-4333-8333-333333333333"

    /// What the machine prints for one busy session in tmux, and one tmux session.
    static func answer(status: String) -> String {
        let tail = #"{"type":"assistant","timestamp":"2025-10-09T08:00:00Z","message":{"model":"claude-opus-4-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000}}}"#
        let record: [String: Any] = [
            "pid": 42, "sessionId": sid, "cwd": "/home/example/api", "entrypoint": "cli", "kind": "interactive",
            "status": status, "activityEpoch": 1_760_000_000, "contextTail": tail,
            "tmux": ["session": "api", "window": 0, "pane": 0, "launch": ""],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["sessions": [record], "windows": []])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n" + V1ProbeReading.separator + "\n1\t1\t1760000000\t1759990000\tapi\n"
    }

    /// A machine whose answer and reachability the case changes as it goes.
    final class Machine: @unchecked Sendable {
        private let lock = NSLock()
        private var status = "busy"
        private var reachable = true
        private(set) var commands: [String] = []

        func set(status: String? = nil, reachable: Bool? = nil) {
            lock.lock()
            if let status { self.status = status }
            if let reachable { self.reachable = reachable }
            lock.unlock()
        }

        func run(_ command: String) throws -> NodeCommandResult {
            lock.lock()
            defer { lock.unlock() }
            commands.append(command)
            guard reachable else { throw NodeLinkError.timedOut("running a command", seconds: 30) }
            return NodeCommandResult(output: answer(status: status), exitCode: 0)
        }
    }

    static func make() -> (ProbeLink, Machine) {
        let machine = Machine()
        let source = V1ProbeSource(identity: node, startedAt: Date(), journal: "probe-test")
        let probe = ProbeLink(source: source, interval: 3600) { command in try machine.run(command) }
        return (probe, machine)
    }

    static let suite = TestSuite("Lights read over ssh, served to the link", [

        TestCase("A look reads the machine with the one read-only command, and the source holds its rows") { t in
            let (probe, machine) = make()
            let answered = try? Blocking.run { await probe.look() }
            t.expectEqual(answered, true, "the machine answered")
            t.expectEqual(machine.commands, [V1ProbeReading.command()], "one command, the probe and tmux's sessions")
            t.expectEqual(probe.source.snapshot(at: Date()).rows?.first?.session.status, "working", "busy is working")
            t.expectEqual(probe.source.tmuxSessions?.map(\.name), ["api"], "tmux's sessions, to open a terminal on")
        },

        TestCase("A V1Link reads those rows like any source's, and follows each change") { t in
            let (probe, machine) = make()
            _ = try? Blocking.run { await probe.look() }
            let link = V1Link(name: "probe-test", pingInterval: 1, backoff: [0.1], tickEvery: nil) { probe.channel() }
            _ = try? Blocking.run { await link.start() }
            t.expect(Blocking.eventually(5) { await link.rows.first?.session.status == "working" }, "the row arrived")
            t.expectEqual((try? Blocking.run { await link.rows.first?.extras.stateBasis }) ?? nil, .sessionFile,
                          "and says it was read, not heard")
            machine.set(status: "idle")
            _ = try? Blocking.run { await probe.look() }
            t.expect(Blocking.eventually(5) { await link.rows.first?.session.status == "idle" }, "the change followed")
            _ = try? Blocking.run { await link.stop() }
        },

        TestCase("A look that gets no answer keeps the rows, says why, and marks them unreachable") { t in
            let (probe, machine) = make()
            _ = try? Blocking.run { await probe.look() }
            machine.set(reachable: false)
            let answered = try? Blocking.run { await probe.look() }
            t.expectEqual(answered, false, "no answer")
            t.expect(((try? Blocking.run { await probe.lastError }) ?? nil)?.contains("longer than") == true, "the reason is kept")
            let row = probe.source.snapshot(at: Date()).rows?.first
            t.expectEqual(row?.session.status, "working", "the last state is kept")
            t.expectEqual(row?.extras.hostReachable, false, "and said unreachable")
        },

        TestCase("A channel to the source refuses writes once closed") { t in
            let (probe, _) = make()
            let channel = probe.channel()
            let refused = try? Blocking.run { () async -> Bool in
                await channel.close()
                do { try await channel.write([0x0A]); return false } catch { return (error as? NodeLinkError) == .closed }
            }
            t.expectEqual(refused, true, "closed is closed")
        },

        TestCase("A terminal's size has two sides between 1 and 1000") { t in
            t.expectEqual(TerminalSize(columns: 45, rows: 30)?.description, "45x30", "a phone")
            t.expectNil(TerminalSize(columns: 0, rows: 30), "no zero side")
            t.expectNil(TerminalSize(columns: 80, rows: 1001), "nothing past 1000")
        },
    ])
}
