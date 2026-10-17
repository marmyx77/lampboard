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
                for original in Set(events.compactMap { ($0["payload"] as? [String: Any])?["session_id"] as? String }) {
                    app.writeTranscript(sessionId: id(original), cwd: workspace, title: "Parity \(original)")
                }
                var mismatches: [String] = []
                for (index, event) in events.enumerated() where index < golden.count {
                    guard var payload = event["payload"] as? [String: Any], let original = payload["session_id"] as? String
                    else { continue }
                    payload["session_id"] = id(original)
                    payload["cwd"] = workspace
                    payload.removeValue(forKey: "transcript_path")
                    app.sendHook(payload, entrypoint: event["entrypoint"] as? String ?? "cli")
                    let expected = golden[index]
                    let reached = app.waitUntil(timeout: 3) {
                        let session = app.session(id: id(original))
                        return (session?.status ?? "absent") == expected.status
                            && (session?.activeSubagents ?? 0) == expected.activeSubagents
                    }
                    if !reached {
                        let session = app.session(id: id(original))
                        mismatches.append("step \(index + 1) \(expected.event): the app says \(session?.status ?? "absent")"
                                          + "/\(session?.activeSubagents ?? 0), lampd says \(expected.status)/\(expected.activeSubagents)")
                    }
                }
                a.expect(mismatches.isEmpty, "the Mac and lampd disagree: \(mismatches.joined(separator: "; "))")
            }
        })
    }
}
