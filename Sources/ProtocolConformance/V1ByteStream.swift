import LampBoardCore
import Foundation

/// A connection to a `v1` source as the conformance suite sees it: bytes that go
/// in, bytes that come out, and nothing else.
///
/// Today one kind exists, `V1LoopbackStream`, joined to a `V1Service` in
/// memory. The same suite is meant to run over ssh — `lampd v1-stdio` in the
/// fake node, the Mac's own server on the test Mac — by implementing these three
/// calls over a process's pipes; nothing in the suite knows the difference.
public protocol V1ByteStream: AnyObject {
    func write(_ bytes: [UInt8]) throws
    /// What arrived within `timeout` seconds: empty when nothing did, `nil`
    /// when the source closed the stream.
    func read(timeout: TimeInterval) throws -> [UInt8]?
    func close()
}

/// A source the conformance suite can be pointed at.
public protocol V1ConformanceTarget {
    /// Shown in the suite's name.
    var name: String { get }
    /// A new connection, made with a key of `role`.
    func connect(role: V1Role) throws -> V1ByteStream
    /// Makes the source's state change `count` times — one event each.
    func provoke(_ count: Int) throws
    /// The ping interval the suite asks for: short, so a real-time run is short.
    var pingInterval: TimeInterval { get }
}

/// A `V1Service` on the other side of a buffer, with a clock of its own.
///
/// `read(timeout:)` moves the clock forward instead of waiting, a tenth of a
/// second at a time, polling the service at each step as a transport's timer
/// would. So a suite asking for a ping every half second takes no time at all.
public final class V1LoopbackStream: V1ByteStream {
    private var service: V1Service
    private let clock: V1ManualClock
    private var pending: [UInt8] = []

    public init(source: V1Source, peer: V1Peer, clock: V1ManualClock) {
        self.service = V1Service(source: source, peer: peer)
        self.clock = clock
    }

    public func write(_ bytes: [UInt8]) throws {
        pending += service.receive(bytes, at: clock.now)
    }

    public func read(timeout: TimeInterval) throws -> [UInt8]? {
        var waited: TimeInterval = 0
        while true {
            pending += service.poll(at: clock.now)
            if !pending.isEmpty {
                defer { pending = [] }
                return pending
            }
            if service.isClosed { return nil }
            if waited >= timeout { return [] }
            let step = min(0.1, timeout - waited)
            clock.advance(step)
            waited += step
        }
    }

    public func close() {
        _ = service.close(reason: "the client closed")
    }
}

/// The time a loopback's service sees: shared by every stream of one target, so
/// that the source and all its connections agree on what "now" is.
public final class V1ManualClock {
    public private(set) var now: Date

    public init(_ start: Date) { now = start }

    public func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// The reference source in memory, as a conformance target.
public final class V1MemoryTarget: V1ConformanceTarget {
    public let name = "the reference source in memory"
    public let pingInterval: TimeInterval = 0.5
    public let source: V1MemorySource
    public let clock: V1ManualClock
    private var made = 0

    public init(start: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        clock = V1ManualClock(start)
        source = V1ReferenceFixture.source(startedAt: start)
        made = V1ReferenceFixture.provoke(source, count: 3, made: made, at: clock.now)
    }

    public static func sessionId(_ n: Int) -> String { V1ReferenceFixture.sessionId(n) }

    public func connect(role: V1Role) throws -> V1ByteStream {
        V1LoopbackStream(source: source, peer: V1Peer(device: "conformance-device", role: role), clock: clock)
    }

    public func provoke(_ count: Int) throws {
        made = V1ReferenceFixture.provoke(source, count: count, made: made, at: clock.now)
    }
}

/// The reference source's data, the same wherever it is served: in memory for
/// the domain suite, behind ssh in a container for the transport's check
/// (`V1ReferenceNode`). Example names only.
public enum V1ReferenceFixture {

    public static func source(startedAt start: Date) -> V1MemorySource {
        let source = V1MemorySource(
            identity: V1SourceIdentity(kind: .node, name: "example-node"), version: "conformance",
            startedAt: start, journal: "conformance-1", retention: 100
        )
        source.setTranscript(session: sessionId(1), messages: [
            .init(role: "user", text: "Check the build.", at: start),
            .init(role: "assistant", text: "The build is green.", at: start),
        ])
        return source
    }

    public static func sessionId(_ n: Int) -> String { String(format: "10000000-0000-4000-8000-%012ld", n) }

    /// Changes the source `count` times, one event each, cycling over three
    /// sessions. Returns the new number of changes made so far.
    public static func provoke(_ source: V1MemorySource, count: Int, made: Int, at now: Date) -> Int {
        var made = made
        for _ in 0..<count {
            made += 1
            let n = (made - 1) % 3 + 1
            let session = SessionSnapshot(
                id: sessionId(n), status: made % 2 == 0 ? "ready" : "working", workspace: "project-\(n)",
                path: "/work/project-\(n)", updatedAt: now, statusSince: now,
                contextPercent: 40, contextConfidence: "exact", costUSD: 0.5, entrypoint: "cli", origin: "terminal",
                title: "Example session \(n)"
            )
            source.upsert(V1Row(session: session, source: source.identity,
                                extras: V1RowExtras(cacheMinutes: 3, readAt: now, terminal: "tmux:project-\(n)")),
                          at: now)
        }
        return made
    }
}
