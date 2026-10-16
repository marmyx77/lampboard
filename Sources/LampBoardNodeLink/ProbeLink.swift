import Foundation
import LampBoardCore

/// The lights of a machine that does not serve `v1` yet, read over ssh on a
/// clock (D176): today the Linux machine, until its service arrives in W4.
///
/// Every `interval` it runs `V1ProbeReading.command` through `run` — for the
/// app, an `ActionConnection`'s `run` — and gives the answer, or its absence,
/// to a `V1ProbeSource`. The app reads that source like any other: `channel()`
/// is a `v1` channel to it in memory, for a `V1Link`, so a row read this way
/// and a row a source serves reach the screen through the same code.
public actor ProbeLink {

    public typealias Runner = @Sendable (String) async throws -> NodeCommandResult

    public nonisolated let source: V1ProbeSource
    /// The last reason there was no answer; `nil` after an answer.
    public private(set) var lastError: String?
    /// Looks so far, answered or not.
    public private(set) var looks = 0

    private let run: Runner
    private let interval: TimeInterval
    private let server: TmuxSizeRule.Server
    private let clock: @Sendable () -> Date
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: seconds between looks; the Mac asks its nodes every 20.
    ///   - run: runs one command on the machine and says how it ended.
    public init(source: V1ProbeSource, interval: TimeInterval = AppConfig.remotePollInterval,
                server: TmuxSizeRule.Server = .default, clock: @escaping @Sendable () -> Date = { Date() },
                run: @escaping Runner) {
        self.source = source
        self.interval = interval
        self.server = server
        self.clock = clock
        self.run = run
    }

    /// One look now. `true` when the machine answered.
    @discardableResult
    public func look() async -> Bool {
        looks += 1
        let asked = clock()
        var reading: V1ProbeReading?
        do {
            let result = try await run(V1ProbeReading.command(server: server))
            reading = V1ProbeReading.parse(result.output, host: source.identity.name, at: asked)
            lastError = reading == nil ? "the machine's answer could not be read (exit \(result.exitCode))" : nil
        } catch {
            lastError = "\(error)"
        }
        source.absorb(reading, at: asked)
        return reading != nil
    }

    /// Looks now and every `interval` until `stop`.
    public func start() {
        guard loop == nil else { return }
        let seconds = interval
        loop = Task {
            while !Task.isCancelled {
                await self.look()
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// A `v1` channel to the source, in memory: what a `V1Link` opens.
    public nonisolated func channel(device: String = "this-device") -> NodeByteChannel {
        LocalV1Channel(source: source, peer: V1Peer(device: device, role: .read), clock: clock)
    }
}

/// A `V1Service` over a source in this process, behind the channel protocol:
/// what is written is answered at once, and what the source does since is
/// delivered every `pollEvery` seconds, pings included.
public final class LocalV1Channel: NodeByteChannel, @unchecked Sendable {
    public let inbound: AsyncStream<[UInt8]>
    private let feed: AsyncStream<[UInt8]>.Continuation
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var service: V1Service
    private var closed = false
    private var poller: Task<Void, Never>?

    public init(source: V1Source, peer: V1Peer, pollEvery: TimeInterval = 0.25,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        service = V1Service(source: source, peer: peer)
        (inbound, feed) = AsyncStream.makeStream(of: [UInt8].self)
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, pollEvery) * 1_000_000_000))
                guard let self, !self.poll() else { return }
            }
        }
    }

    deinit { poller?.cancel() }

    public func write(_ bytes: [UInt8]) async throws {
        let now = clock()
        let out: [UInt8]? = lock.withLock {
            guard !closed else { return nil }
            return service.receive(bytes, at: now)
        }
        guard let out else { throw NodeLinkError.closed }
        deliver(out)
    }

    public func close() async {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        poller?.cancel()
        if first { feed.finish() }
    }

    /// Delivers what the source did since the last call; `true` once closed.
    private func poll() -> Bool {
        let now = clock()
        let (out, isClosed) = lock.withLock { () -> ([UInt8], Bool) in
            closed ? ([], true) : (service.poll(at: now), false)
        }
        deliver(out)
        return isClosed
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for piece in V1Frame.pieces(bytes) { feed.yield(piece) }
    }
}
