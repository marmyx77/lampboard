import Foundation
import LampBoardCore
import LampDKit

/// What the suites build their machines from: made-up homes in the temporary
/// folder, made-up sessions, example names only.
enum F {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let node = V1SourceIdentity(kind: .node, name: "example-node")
    static let a = "11111111-1111-4111-8111-111111111111"
    static let b = "22222222-2222-4222-8222-222222222222"
    static let c = "33333333-3333-4333-8333-333333333333"

    /// An assistant record as the probe's miniature carries it, its turn ended.
    static let ended = #"{"type":"assistant","timestamp":"2027-01-15T08:00:00Z","message":{"model":"claude-opus-4-5","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":40000}}}"#
    /// The same, its turn still open (a tool was asked for).
    static let open = #"{"type":"assistant","timestamp":"2027-01-15T08:00:00Z","message":{"model":"claude-opus-4-5","stop_reason":"tool_use","usage":{"input_tokens":10,"cache_creation_input_tokens":2000,"cache_read_input_tokens":40000}}}"#

    static func record(_ id: String, pid: Int, status: String, tail: String = open, entrypoint: String = "cli",
                       kind: String = "interactive", cwd: String = "/home/dev/project", tmux: String? = nil) -> [String: Any] {
        var record: [String: Any] = [
            "pid": pid, "sessionId": id, "cwd": cwd, "entrypoint": entrypoint, "kind": kind,
            "status": status, "activityEpoch": 1_800_000_000, "contextTail": tail,
        ]
        if let tmux { record["tmux"] = ["session": tmux, "window": 0, "pane": 0, "launch": ""] }
        return record
    }

    static func reading(_ records: [[String: Any]]) -> V1ProbeReading {
        let data = (try? JSONSerialization.data(withJSONObject: ["sessions": records, "windows": []])) ?? Data()
        let report = (try? RemoteSessionsDecoder.report(from: data, host: "", at: t0)) ?? .init(sessions: [], windows: [])
        return V1ProbeReading(report: report, tmuxSessions: [])
    }

    static func look(_ records: [[String: Any]], at: Date = t0, jobs: [String: BackgroundJob] = [:]) -> LocalProbe.Look {
        LocalProbe.Look(reading: reading(records), jobs: jobs, at: at)
    }

    /// A home of its own under the temporary folder, removed by the caller.
    static func home(_ name: String = "home") -> LampDPaths {
        let root = NSTemporaryDirectory() + "lampd-tests-\(getpid())-\(name)-\(UInt32.random(in: 0...UInt32.max))"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return LampDPaths.current(environment: ["LAMPBOARD_HOME": root, "HOME": root])
    }

    static func remove(_ paths: LampDPaths) { try? FileManager.default.removeItem(atPath: paths.home) }

    /// A public key of `type` whose blob is well formed: the type, then bytes.
    static func key(_ type: String = "ecdsa-sha2-nistp256", seed: UInt8 = 1) -> String {
        var blob = Data()
        let name = Array(type.utf8)
        blob.append(contentsOf: [0, 0, 0, UInt8(name.count)])
        blob.append(contentsOf: name)
        blob.append(contentsOf: [0, 0, 0, 8] + Array(repeating: seed, count: 8))
        return "\(type) \(blob.base64EncodedString())"
    }

    static func source(_ paths: LampDPaths, mode: V1ServingMode = .live) -> NodeSource {
        NodeSource(identity: node, mode: mode, paths: paths, version: "test", startedAt: t0)
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
