import LampBoardCore
import Foundation

/// Rows, sources and wire helpers shared by the `v1` suites. Every name and path
/// is made up: nothing here describes a real machine.
enum V1Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    static let mac = V1SourceIdentity(kind: .mac, name: "Example Mac")
    static let node = V1SourceIdentity(kind: .node, name: "example-node")
    static let reader = V1Peer(device: "phone-1", role: .read)
    static let actor = V1Peer(device: "phone-1", role: .action)

    static func sid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012ld", n) }

    static func row(_ n: Int, status: String = "working", source: V1SourceIdentity = mac, at: Date = t0) -> V1Row {
        V1Row(
            session: SessionSnapshot(
                id: sid(n), status: status, workspace: "project-\(n)", path: "/work/project-\(n)",
                updatedAt: at, statusSince: at, costUSD: 1.25, entrypoint: "cli", origin: "terminal"
            ),
            source: source,
            extras: V1RowExtras(cacheMinutes: 4, terminal: "tmux:project-\(n)")
        )
    }

    /// A Mac source holding `rows` rows, one event each.
    static func source(rows: Int = 2, retention: Int = 1000, journal: String = "j1") -> V1MemorySource {
        let source = V1MemorySource(identity: mac, version: "2.4.0", startedAt: t0, journal: journal, retention: retention)
        for n in 0..<rows { source.upsert(row(n + 1), at: t0) }
        return source
    }

    static func frame(_ request: V1Request, id: Int? = nil) -> [UInt8] {
        V1Frame.encode((try? V1Codec.encode(V1ClientMessage(id: id, request))) ?? [])
    }

    static func hello(id: Int? = 1) -> [UInt8] { frame(.hello(protocol: V1Protocol.version, client: "test"), id: id) }

    /// The messages in `bytes`; a frame that does not decode is a test failure
    /// the caller sees as a missing message.
    static func replies(_ bytes: [UInt8]) -> [V1ServerMessage] {
        var reader = V1FrameReader()
        reader.push(bytes)
        var out: [V1ServerMessage] = []
        while let frame = (try? reader.next()) ?? nil {
            if let message = try? V1Codec.decodeReply(frame) { out.append(message) }
        }
        return out
    }

    static func types(_ bytes: [UInt8]) -> [String] { replies(bytes).map(\.reply.type) }

    /// A service that has already said hello.
    static func greeted(_ source: V1Source, peer: V1Peer = reader) -> V1Service {
        var service = V1Service(source: source, peer: peer)
        _ = service.receive(hello(), at: t0)
        return service
    }

    static func failure(_ bytes: [UInt8]) -> V1Failure? {
        for message in replies(bytes) { if case .error(let failure) = message.reply { return failure } }
        return nil
    }
}
