import Foundation
import LampBoardCore
@preconcurrency import LampBoardMacSource
import ProtocolConformance

/// Example data only: names and paths of no real person or machine.
enum MacFixtures {

    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    static let mac = V1SourceIdentity(kind: .mac, name: "Example Mac")

    static func sid(_ n: Int) -> String { String(format: "20000000-0000-4000-8000-%012ld", n) }

    static func snapshot(_ n: Int, status: String = "working", host: String? = nil, at: Date = t0,
                         transcript: String? = nil) -> SessionSnapshot {
        SessionSnapshot(
            id: sid(n), status: status, workspace: "project-\(n)", path: "/work/project-\(n)",
            updatedAt: at, statusSince: at, contextPercent: 30, contextConfidence: "exact", costUSD: 0.75,
            transcriptPath: transcript, host: host, entrypoint: "cli", origin: "terminal", title: "Example \(n)"
        )
    }

    /// What a source's actions do in the tests: they are recorded, and the
    /// row they name must exist (the source checks that first).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var done: [V1Command] = []
        var commands: [V1Command] { lock.lock(); defer { lock.unlock() }; return done }
        func add(_ command: V1Command) { lock.lock(); done.append(command); lock.unlock() }
    }

    static func actions(_ recorder: Recorder = Recorder(), devices: MacDevices? = nil) -> MacSourceActions {
        MacSourceActions(
            perform: { command, _ in recorder.add(command); return nil },
            devices: { request in
                guard let devices else { return .success([]) }
                switch request.action {
                case .list: return .success(devices.v1Devices)
                case .revoke:
                    guard let id = request.device, (try? devices.revoke(id)) == true else {
                        return .failure(V1Failure(.notFound, "no device \(request.device ?? "")"))
                    }
                    return .success(devices.v1Devices)
                }
            }
        )
    }

    static func source(_ recorder: Recorder = Recorder(), devices: MacDevices? = nil) -> MacV1Source {
        MacV1Source(identity: mac, version: "2.4.0-test", startedAt: t0, actions: actions(recorder, devices: devices), retention: 100)
    }

    static func temporaryDirectory(_ name: String) -> String {
        let path = NSTemporaryDirectory() + "lb-mac-\(name)-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return path
    }
}

/// The Mac's source in memory, as the conformance battery's target: the same
/// cases the reference source and `lampd` pass.
final class MacMemoryTarget: V1ConformanceTarget {
    let name = "the Mac's source in memory"
    let pingInterval: TimeInterval = 0.5
    let source = MacFixtures.source()
    let clock = V1ManualClock(MacFixtures.t0)
    private var made = 0

    init() { try? provoke(3) }

    func connect(role: V1Role) throws -> V1ByteStream {
        V1LoopbackStream(source: source, peer: V1Peer(device: "conformance-device", role: role), clock: clock)
    }

    func provoke(_ count: Int) throws {
        made = MacProvoker.provoke(source, count: count, made: made, at: clock.now)
    }
}

/// Changes the Mac's column `count` times, one event each, over three rows.
enum MacProvoker {
    static func provoke(_ source: MacV1Source, count: Int, made: Int, at now: Date) -> Int {
        var made = made
        var current = Dictionary(uniqueKeysWithValues: source.currentRows.map { ($0.id, $0.session) })
        for _ in 0..<count {
            made += 1
            let n = (made - 1) % 3 + 1
            current[MacFixtures.sid(n)] = MacFixtures.snapshot(n, status: made % 2 == 0 ? "ready" : "working",
                                                               at: now.addingTimeInterval(Double(made)))
            source.update(MacRows.rows(Array(current.values).sorted { $0.id < $1.id }, mac: MacFixtures.mac), at: now)
        }
        return made
    }
}
