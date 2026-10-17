import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What `lampd status` prints and the Quadro reads: the service as it answers,
/// with the age of its state, which is what a liveness check cannot see.
public struct LampDStatus: Equatable, Sendable {
    public let version: String
    public let name: String
    public let mode: V1ServingMode
    public let pid: Int32
    public let startedAt: Date
    public let binaryModifiedAt: Date?
    public let configModifiedAt: Date?
    public let journal: String
    public let seq: Int
    public let rows: Int?
    public let lastEventAt: Date?
    public let lastProbeAt: Date?
    public let stateAgeSeconds: Double?
    public let lastProbeProblem: String?
    public let contract: ContractStamp?

    public static func report(source: NodeSource, config: LampDConfig, paths: LampDPaths, at now: Date) -> LampDStatus {
        let status = source.status(at: now)
        let age = V1StateAge(seq: status.seq, lastEventAt: status.lastEventAt, lastProbeAt: status.lastProbeAt, at: now)
        return LampDStatus(
            version: status.version, name: config.name, mode: source.mode, pid: getpid(), startedAt: status.startedAt,
            binaryModifiedAt: status.binaryModifiedAt, configModifiedAt: status.configModifiedAt,
            journal: status.journal, seq: status.seq, rows: source.snapshot(at: now).rows?.count,
            lastEventAt: status.lastEventAt, lastProbeAt: status.lastProbeAt, stateAgeSeconds: age.seconds,
            lastProbeProblem: source.lastProbe.problem, contract: ContractStamp.load(paths.contractFile)
        )
    }

    public func json() throws -> String {
        var object: [String: Any] = [
            "version": version, "name": name, "mode": mode.rawValue, "pid": Int(pid), "startedAt": Self.time(startedAt),
            "journal": journal, "seq": seq,
        ]
        object["binaryModifiedAt"] = binaryModifiedAt.map(Self.time)
        object["configModifiedAt"] = configModifiedAt.map(Self.time)
        object["rows"] = rows
        object["lastEventAt"] = lastEventAt.map(Self.time)
        object["lastProbeAt"] = lastProbeAt.map(Self.time)
        object["stateAgeSeconds"] = stateAgeSeconds
        object["lastProbeProblem"] = lastProbeProblem
        object["contract"] = contract?.object
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func time(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Asks the running service over its socket; `nil` when none answers.
    public static func ask(_ socket: String, line: String, timeout: TimeInterval = 25) -> String? {
        guard let fd = UnixSocket.connect(socket) else { return nil }
        defer { close(fd) }
        UnixSocket.sendAll(fd, Array((line + "\n").utf8))
        guard UnixSocket.readable(fd, timeout: timeout) else { return nil }
        return UnixSocket.readLine(fd, limit: 1 << 20)
    }
}

/// The last check of Claude Code's contract on this machine (E5, Q22), as the
/// contract timer leaves it in the state folder: the version it was checked
/// against, when, and whether it held.
public struct ContractStamp: Equatable, Sendable {
    public let claudeVersion: String
    public let checkedAt: Date
    /// `pass`, `fail` or `cannot-check`.
    public let outcome: String
    public let live: Bool

    public init(claudeVersion: String, checkedAt: Date, outcome: String, live: Bool) {
        self.claudeVersion = claudeVersion
        self.checkedAt = checkedAt
        self.outcome = outcome
        self.live = live
    }

    public static func load(_ path: String) -> ContractStamp? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["claudeVersion"] as? String, let at = (object["checkedAt"] as? String).flatMap(ISO8601DateFormatter().date),
              let outcome = object["outcome"] as? String else { return nil }
        return ContractStamp(claudeVersion: version, checkedAt: at, outcome: outcome, live: object["live"] as? Bool ?? false)
    }

    var object: [String: Any] {
        ["claudeVersion": claudeVersion, "checkedAt": LampDStatus.time(checkedAt), "outcome": outcome, "live": live]
    }
}
