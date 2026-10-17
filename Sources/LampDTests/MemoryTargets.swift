import Foundation
import LampBoardCore
import LampDKit
import ProtocolConformance
import TestKit

/// The node's source in this process, behind a buffer: the conformance
/// battery run against `lampd`'s own rules before any ssh is involved. The
/// same battery runs against the real `lampd` behind OpenSSH in the fake node
/// (Scripts/test-lampd.sh).
final class NodeMemoryTarget: V1ConformanceTarget {
    let name: String
    let pingInterval: TimeInterval = 0.5
    private let source: NodeSource
    private let clock = V1ManualClock(F.t0)
    private var flips = 0
    private let paths: LampDPaths

    init(mode: V1ServingMode) {
        name = "lampd's source in memory (\(mode.rawValue))"
        paths = F.home("conformance-\(mode.rawValue)")
        source = F.source(paths, mode: mode)
        source.absorb(F.look(Self.records(flips: 0), at: clock.now))
    }

    deinit { F.remove(paths) }

    /// Two sessions; the first flips between working and idle, one event a flip.
    static func records(flips: Int) -> [[String: Any]] {
        [
            F.record(F.a, pid: 10, status: flips % 2 == 0 ? "busy" : "idle"),
            F.record(F.b, pid: 11, status: "waiting"),
        ]
    }

    func connect(role: V1Role) throws -> V1ByteStream {
        V1LoopbackStream(source: source, peer: V1Peer(device: "conformance", role: role), clock: clock)
    }

    func provoke(_ count: Int) throws {
        for _ in 0..<count {
            flips += 1
            source.absorb(F.look(Self.records(flips: flips), at: clock.now))
        }
    }
}
