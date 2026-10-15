import Foundation
import LampBoardCore

/// The `v1` client of the Core, carried over channels that come and go.
///
/// `V1Client` knows no transport; this is the transport's half of its contract
/// (§2.2 of the mobile plan): open a channel, write what `connect` returns, hand
/// every chunk to `receive`, call `tick` on a clock, and when an answer says
/// `.reconnect` drop the channel and open another. The client then comes back
/// with `since=<the last event it holds>`, so a cut costs no event and repeats
/// none (S-R: 1000 events, a TCP cut, 0 holes, 0 doubles).
///
/// It opens channels through `open`, which for the app is a NodeLink
/// connection's `openV1()` and for the tests a `V1Service` in memory.
public actor V1Link {

    public typealias Opener = () async throws -> NodeByteChannel

    public enum Status: Equatable, Sendable {
        case connecting
        case live
        /// Waiting `seconds` before the next attempt, after `reason`.
        case waiting(seconds: TimeInterval, reason: String)
        /// The machine and this app cannot talk until one of them is updated.
        case incompatible(String)
        case stopped
    }

    public nonisolated let events: AsyncStream<V1Client.Event>
    public private(set) var status: Status = .connecting
    /// Channels opened so far, the first included.
    public private(set) var opened = 0

    private var client: V1Client
    private let open: Opener
    private let clock: () -> Date
    private let backoff: [TimeInterval]
    private let continuation: AsyncStream<V1Client.Event>.Continuation
    private var channel: NodeByteChannel?
    private var connection = 0
    private var failures = 0
    private var running: Task<Void, Never>?
    private var ticking: Task<Void, Never>?

    /// - Parameters:
    ///   - backoff: the waits between failed attempts, the last one repeated.
    ///   - tickEvery: how often the client is asked whether its state became
    ///     old; `nil` leaves it to `tick()`, as the tests do.
    public init(name: String, pingInterval: TimeInterval = V1Protocol.defaultPingInterval,
                backoff: [TimeInterval] = [1, 2, 5, 10, 30], tickEvery: TimeInterval? = 1,
                clock: @escaping () -> Date = Date.init, open: @escaping Opener) {
        self.client = V1Client(name: name, pingInterval: pingInterval, at: clock())
        self.open = open
        self.clock = clock
        self.backoff = backoff.isEmpty ? [1] : backoff
        (events, continuation) = AsyncStream.makeStream(of: V1Client.Event.self)
        if let tickEvery { Task { await self.startTicking(every: tickEvery) } }
    }

    // MARK: - What the app reads

    public var rows: [V1Row] { client.rows }
    public var rowsKnown: Bool { client.rowsKnown }
    public var isStale: Bool { client.isStale }
    public var hello: V1Hello? { client.hello }
    public var lastSeq: Int? { client.lastSeq }
    /// How long a silence may last before the state is declared old.
    public var staleAfter: TimeInterval { client.staleAfter }

    // MARK: - Running

    /// Starts connecting, and keeps a channel open until `stop`.
    public func start() {
        guard running == nil else { return }
        running = Task { await self.loop() }
    }

    public func stop() async {
        status = .stopped
        running?.cancel()
        ticking?.cancel()
        if let channel { await channel.close() }
        channel = nil
        continuation.finish()
    }

    /// Sends a request on the live channel; its answer arrives on `events`.
    @discardableResult
    public func send(_ request: V1Request) async throws -> Int {
        guard let channel, status == .live else { throw NodeLinkError.closed }
        let (id, bytes) = client.request(request)
        try await channel.write(bytes)
        return id
    }

    /// The clock moved: the state may have become old. Called every `tickEvery`.
    public func tick() async {
        guard status != .stopped else { return }
        handle(client.tick(at: clock()))
        if needsReconnect { await dropChannel() }
    }

    // MARK: - The loop

    private var needsReconnect = false

    private func loop() async {
        while !Task.isCancelled, status != .stopped {
            if case .incompatible = status { return }
            status = .connecting
            let next: NodeByteChannel
            do {
                next = try await open()
            } catch {
                await wait(after: "\(error)")
                continue
            }
            // `stop` may have come in while `open` was waiting: a channel that
            // arrives after it is closed, not adopted.
            if status == .stopped || Task.isCancelled {
                await next.close()
                return
            }
            opened += 1
            channel = next
            needsReconnect = false
            let (id, first) = client.connect(at: clock())
            connection = id
            do {
                try await next.write(first)
            } catch {
                await dropChannel()
                await wait(after: "\(error)")
                continue
            }
            guard status != .stopped else { await dropChannel(); return }
            status = .live
            let liveSince = clock()
            for await chunk in next.inbound {
                handle(client.receive(chunk, on: id, at: clock()))
                if needsReconnect { break }
            }
            client.disconnected(id)
            await dropChannel()
            if case .incompatible = status { return }
            if status == .stopped || Task.isCancelled { return }
            if clock().timeIntervalSince(liveSince) >= 1 { failures = 0 }
            if !needsReconnect || clock().timeIntervalSince(liveSince) < 1 {
                // The machine ended the channel without a word, or a channel
                // keeps failing as soon as it opens: wait before the next one.
                await wait(after: needsReconnect ? "the channel failed at once" : "the channel ended")
            }
        }
    }

    private func handle(_ answers: [V1Client.Event]) {
        for answer in answers {
            switch answer {
            case .reconnect:
                needsReconnect = true
            case .incompatible(let why):
                status = .incompatible(why)
                needsReconnect = true
            default:
                break
            }
            continuation.yield(answer)
        }
    }

    private func dropChannel() async {
        guard let current = channel else { return }
        channel = nil
        await current.close()
    }

    private func wait(after reason: String) async {
        guard status != .stopped, !Task.isCancelled else { return }
        let seconds = backoff[min(failures, backoff.count - 1)]
        failures += 1
        status = .waiting(seconds: seconds, reason: reason)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func startTicking(every seconds: TimeInterval) {
        // `stop` can come before this task first runs: then there is nothing to tick.
        guard status != .stopped else { return }
        ticking = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self.tick()
            }
        }
    }
}
