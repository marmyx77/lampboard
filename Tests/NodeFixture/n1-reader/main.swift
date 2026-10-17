import Foundation
import LampBoardCore
import LampBoardNodeLink
import TestKit

// The app one version behind, as far as `lampd` is concerned: the Core and
// NodeLink of the commit the TestFlight build was made from, built by
// Scripts/test-lampd.sh from that commit and pointed at the current `lampd`.
// It reads the lights with the read key as the phone will, follows a change,
// and looks at the machine over ssh with the action key as the phone does
// today, against a node where `lampd` wrote the phone's lines.
//
//   N1Reader --host H --port P --user U --host-key F --keys <dir> --flip <command>
//
// `--flip -` is for a real machine, where the check may change nothing: the
// rows through the read key and the look with the action key, no change and so
// no event to follow.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("N1Reader: --\(name) is required\n".utf8))
        exit(2)
    }
    return arguments[index + 1]
}
func key(_ name: String) -> Data {
    let text = (try? String(contentsOfFile: option("keys") + "/\(name).key", encoding: .utf8)) ?? ""
    return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()
}

guard #available(macOS 15.0, *) else { exit(2) }
do {
    let endpoint = NodeEndpoint(host: option("host"), port: Int(option("port")) ?? 22, user: option("user"))
    let hostKey = try NodeHostKey(openSSH: String(contentsOfFile: option("host-key"), encoding: .utf8))
    let readKey = try ReadKey(rawRepresentation: key("read"))
    let actionKey = try ActionKey(rawRepresentation: key("action"))
    var failures: [String] = []

    let link = V1Link(name: "n-1", pingInterval: 1, backoff: [0.2]) {
        let connection = try await NodeLink.read(endpoint, trust: .pinned(hostKey), key: readKey)
        return try await connection.openV1()
    }
    _ = try? Blocking.run { await link.start() }
    if !Blocking.eventually(20, { await link.rows.count >= 1 }) { failures.append("no rows through the read key") }
    let rowsRead = (try? Blocking.run { await link.rows.count }) ?? 0
    if option("flip") != "-" {
        let before = (try? Blocking.run { await link.lastSeq }) ?? nil
        let flipped = try Blocking.run(60) { () async throws -> Int in
            let action = try await NodeLink.act(endpoint, trust: .pinned(hostKey), key: actionKey)
            defer { Task { await action.close() } }
            return try await action.run(option("flip")).exitCode
        }
        if flipped != 0 { failures.append("the change could not be made (exit \(flipped))") }
        if !Blocking.eventually(20, { await link.lastSeq.map { $0 > (before ?? 0) } ?? false }) {
            failures.append("no event followed the change")
        }
    }
    _ = try? Blocking.run { await link.stop() }

    let source = V1ProbeSource(identity: V1SourceIdentity(kind: .node, name: "n-1"), startedAt: Date(), journal: "n-1")
    let answered = try Blocking.run(60) { () async throws -> Bool in
        let action = try await NodeLink.act(endpoint, trust: .pinned(hostKey), key: actionKey)
        defer { Task { await action.close() } }
        let probe = ProbeLink(source: source, interval: 3600) { command in try await action.run(command) }
        return await probe.look()
    }
    if !answered || (source.snapshot(at: Date()).rows ?? []).isEmpty {
        failures.append("the look over ssh with the action key found no rows")
    }

    if failures.isEmpty {
        let looked = (source.snapshot(at: Date()).rows ?? []).count
        print("N1Reader: \(rowsRead) rows through the read key, \(looked) from the look with the action key")
        print("N1Reader: the app one version behind reads lampd and still looks over ssh")
        exit(0)
    }
    for failure in failures { print("N1Reader: \(failure)") }
    exit(1)
} catch {
    print("N1Reader: \(error)")
    exit(1)
}
