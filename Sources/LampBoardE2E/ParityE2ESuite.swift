import Foundation
import LampBoardCore
import TestKit

/// The recorded hook flows of the fake node, played into the real app, against
/// the golden files `lampd` is held to (§6.2 of the mobile plan, "parity on
/// recordings").
///
/// From W5 the Linux machine's `lampd` reduces the hooks of its sessions in tee
/// with the Mac, and both must show every session in the same state after every
/// event. `Scripts/test-lampd.sh` compares `lampd replay` with
/// `Tests/NodeFixture/parity/<flow>.json`; this compares the Mac with the same
/// files. A reducer that drifts on either side turns one of the two red.
enum ParityE2ESuite {

    struct Step: Decodable {
        let event: String
        let session: String
        let status: String
        let activeSubagents: Int
    }

    static let flows = ["demo-standard", "e2e-cycle", "late-signals"]

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · parity with lampd on recorded flows", flows.map { flow in
            TestCase("\(flow): the app's lamp after every event is the golden one") { a in
                let root = FileManager.default.currentDirectoryPath + "/Tests/NodeFixture"
                guard let lines = try? String(contentsOfFile: "\(root)/flows/\(flow).jsonl", encoding: .utf8),
                      let golden = FileManager.default.contents(atPath: "\(root)/parity/\(flow).json")
                          .flatMap({ try? JSONDecoder().decode([Step].self, from: $0) })
                else { a.expect(false, "the flow or its golden file is missing under \(root)"); return }
                let events = lines.split(separator: "\n").compactMap { line -> [String: Any]? in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                }.enumerated().sorted {
                    (($0.element["at"] as? NSNumber)?.doubleValue ?? 0, $0.offset) < (($1.element["at"] as? NSNumber)?.doubleValue ?? 0, $1.offset)
                }.map(\.element)
                a.expectEqual(events.count, golden.count, "one golden step per event")
                let workspace = LifecycleSuite.workspace
                let run = String(UInt32.random(in: 0...UInt32.max), radix: 36)
                func id(_ original: String) -> String { "parity-\(run)-\(original)" }
                // A conversation for each session, where the app looks for it: a
                // session that only starts earns no row without one.
                //
                // And a process, as a real one has: the sweep keeps a terminal
                // session's row only while its process lives. Without one, the
                // first sweep that runs while another session's process is alive
                // takes every row of the flow away ("lost 7 to reconcile" in the
                // gate of 18 October): the parity was then a race with the clock.
                let originals = Set(events.compactMap { ($0["payload"] as? [String: Any])?["session_id"] as? String })
                var processes: [String: Process] = [:]
                func end(_ original: String) {
                    guard let process = processes.removeValue(forKey: original) else { return }
                    try? FileManager.default.removeItem(
                        at: app.home.appendingPathComponent(".claude/sessions/\(process.processIdentifier).json"))
                    process.terminate()
                    process.waitUntilExit()
                }
                defer { for original in Array(processes.keys) { end(original) } }
                // A neighbour that lives, as there always is on a real machine:
                // the sweep only takes rows away when it saw someone alive, so
                // without one this check would pass for the wrong reason when the
                // flow runs on its own.
                for original in originals.union(["neighbour"]) {
                    app.writeTranscript(sessionId: id(original), cwd: workspace, title: "Parity \(original)")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                    process.arguments = ["600"]
                    guard (try? process.run()) != nil else { a.expect(false, "no process for \(original)"); return }
                    processes[original] = process
                    app.writeLiveSession(sessionId: id(original), cwd: workspace, entrypoint: "cli", pid: process.processIdentifier)
                }
                var mismatches: [String] = []
                for (index, event) in events.enumerated() where index < golden.count {
                    guard var payload = event["payload"] as? [String: Any], let original = payload["session_id"] as? String
                    else { continue }
                    // A session that ends has no process any more.
                    if payload["hook_event_name"] as? String == "SessionEnd" { end(original) }
                    payload["session_id"] = id(original)
                    payload["cwd"] = workspace
                    payload.removeValue(forKey: "transcript_path")
                    app.sendHook(payload, entrypoint: event["entrypoint"] as? String ?? "cli")
                    let expected = golden[index]
                    let sent = Date()
                    var seen: [String] = []
                    let reached = app.waitUntil(timeout: 3) {
                        let session = app.session(id: id(original))
                        let word = "\(session?.status ?? "absent")/\(session?.activeSubagents ?? 0)"
                        if seen.last?.hasSuffix(" " + word) != true {
                            seen.append(String(format: "%.2fs %@", Date().timeIntervalSince(sent), word))
                        }
                        return (session?.status ?? "absent") == expected.status
                            && (session?.activeSubagents ?? 0) == expected.activeSubagents
                    }
                    if !reached {
                        let session = app.session(id: id(original))
                        // What the app went through while it was waited for, and the
                        // live session files a sweep would have kept alive.
                        let live = (try? FileManager.default.contentsOfDirectory(
                            atPath: app.home.appendingPathComponent(".claude/sessions").path)) ?? []
                        mismatches.append("step \(index + 1) \(expected.event): the app says \(session?.status ?? "absent")"
                                          + "/\(session?.activeSubagents ?? 0), lampd says \(expected.status)/\(expected.activeSubagents)"
                                          + " (seen: \(seen.joined(separator: ", ")); live files: \(live.sorted().joined(separator: ", ")))")
                    }
                }
                // The last lamp of every session, through two sweeps: the rows a
                // flow leaves must survive the app's realignment, every time,
                // not only when no sweep happened to fall inside the flow.
                var last: [String: String] = [:]
                for (index, event) in events.enumerated() where index < golden.count {
                    if let original = (event["payload"] as? [String: Any])?["session_id"] as? String { last[original] = golden[index].status }
                }
                let held = app.holdsThroughTwoSweeps {
                    last.allSatisfy { original, status in (app.session(id: id(original))?.status ?? "absent") == status }
                }
                if !held {
                    let now = last.keys.sorted().map { "\($0) \(app.session(id: id($0))?.status ?? "absent") (lampd \(last[$0] ?? ""))" }
                    mismatches.append("after two sweeps: \(now.joined(separator: ", "))")
                }
                // With LAMPBOARD_DEBUG set, what the app itself said about these rows.
                let debug = (try? String(contentsOf: app.home.appendingPathComponent(".lampboard/debug.log"), encoding: .utf8)) ?? ""
                let said = debug.split(separator: "\n").filter { $0.contains("lost") || $0.contains("parity-") }.suffix(12)
                a.expect(mismatches.isEmpty, "the Mac and lampd disagree: \(mismatches.joined(separator: "; "))"
                         + (said.isEmpty ? "" : "\n" + said.joined(separator: "\n")))
            }
        })
    }
}
