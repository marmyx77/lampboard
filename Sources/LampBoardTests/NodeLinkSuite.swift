import Foundation
import LampBoardCore
@testable import LampBoardNodeLink
import ProtocolConformance
import TestKit

/// NodeLink without a network (D175): the host key verdict, the two keys, the
/// 32 KiB writes, the deadlines, and the `v1` link carried over channels that
/// end, fall silent and come back. The same over a real ssh is
/// `Scripts/test-nodelink.sh`.
enum NodeLinkSuite {

    /// Example keys made for this suite, describing no machine.
    static let exampleKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII7ZP6UAvWa890kXD6L7MOrx15hhbNiW79wLV9FVRIOk example-node"
    static let otherKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBNwrPzYyJ8ChKFYTkKIrN0+OnzpSP8EnNATyYyTHR3 other"

    static let suite = TestSuite("NodeLink", [

        TestCase("A pinned host key lets that key in and refuses any other") { t in
            guard let pinned = try? NodeHostKey(openSSH: exampleKey), let other = try? NodeHostKey(openSSH: otherKey) else {
                t.expect(false, "the example keys do not parse"); return
            }
            t.expectEqual(HostKeyVerdict(trust: .pinned(pinned), presented: pinned), .accepted(pinned), "the same key")
            t.expectEqual(HostKeyVerdict(trust: .pinned(pinned), presented: other),
                          .refused(presented: other, expected: pinned), "another key")
        },

        TestCase("Trust on first use is asked for by name, and hands back the key to pin") { t in
            guard let presented = try? NodeHostKey(openSSH: otherKey) else { t.expect(false, "no key"); return }
            t.expectEqual(HostKeyVerdict(trust: .firstUse, presented: presented), .accepted(presented), "accepted once")
        },

        TestCase("A host key is read without its comment, and printed as ssh-keygen prints it") { t in
            let key = try? NodeHostKey(openSSH: exampleKey + "\n")
            t.expectEqual(key?.openSSH, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII7ZP6UAvWa890kXD6L7MOrx15hhbNiW79wLV9FVRIOk",
                          "algorithm and key, no comment")
            t.expectEqual(key?.fingerprint, "SHA256:YojHW7/8p5T/BBgwlz+OKVjF9QceYgT8hCTqoNk+BkA", "ssh-keygen -l")
            t.expect((try? NodeHostKey(openSSH: "ssh-ed25519 not-base64")) == nil, "garbage is refused")
            t.expect((try? NodeHostKey(openSSH: "")) == nil, "nothing is refused")
        },

        TestCase("The read key and the action key are P-256 keys OpenSSH can authorise") { t in
            let read = ReadKey.generate(), action = ActionKey.generate()
            t.expect(read.publicKey.hasPrefix("ecdsa-sha2-nistp256 "), "read: \(read.publicKey.prefix(24))")
            t.expect(action.publicKey.hasPrefix("ecdsa-sha2-nistp256 "), "action")
            t.expect(read.publicKey != action.publicKey, "two keys, not one")
            t.expectEqual(try? ReadKey(rawRepresentation: read.rawRepresentation).publicKey, read.publicKey, "it round-trips")
            t.expect((try? ActionKey(rawRepresentation: Data([1, 2, 3]))) == nil, "a key that is not one is refused")
        },

        TestCase("Every write is cut at 32 KiB, in order") { t in
            let bytes = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            let pieces = try? Blocking.run { () async throws -> [[UInt8]] in
                var seen: [[UInt8]] = []
                try await NodeWrites.inPieces(bytes) { seen.append($0) }
                return seen
            }
            t.expectEqual(pieces?.count, 4, "four pieces")
            t.expect(pieces?.allSatisfy { $0.count <= 32 * 1024 } ?? false, "none over 32 KiB")
            t.expect(pieces.map { $0.flatMap { $0 } == bytes } ?? false, "nothing lost, nothing moved")
        },

        TestCase("A deadline answers when the operation never does, and runs what expiry asks") { t in
            let expired = Flag()
            let start = Date()
            var failure: Error?
            do {
                _ = try Blocking.run(10) {
                    try await NodeDeadline.run(0.2, "waiting for nothing", expired: { expired.set() }) {
                        await Never.forever()
                    }
                }
            } catch { failure = error }
            t.expectEqual(failure as? NodeLinkError, .timedOut("waiting for nothing", seconds: 0.2), "timed out")
            t.expect(Date().timeIntervalSince(start) < 3, "in time: \(Date().timeIntervalSince(start)) s")
            t.expect(expired.isSet, "expiry ran")
        },

        TestCase("A result that arrives after its deadline is handed over to be disposed of") { t in
            let late = Flag()
            let result = Result { try Blocking.run(10) {
                try await NodeDeadline.run(0.1, "a slow connection", late: { (value: Int) in if value == 7 { late.set() } }) {
                    await Never.after(0.4, returning: 7)
                }
            } }
            t.expect((try? result.get()) == nil, "the caller was not kept waiting")
            t.expect(Blocking.eventually(5) { late.isSet }, "the late value reached `late`")
        },

        TestCase("A channel the machine closed first is a normal end; a refusal is not") { t in
            t.expect(NodeLinkError.isNormalEnd(ChannelErrorFixture.alreadyClosed), "alreadyClosed")
            t.expect(!NodeLinkError.isNormalEnd(NodeLinkError.refused("channel")), "refused")
        },

        TestCase("The link says hello, takes the state, and follows the events") { t in
            let bench = Bench()
            defer { bench.stop() }
            t.expect(Blocking.eventually { await bench.link.rows.count == 3 }, "three rows")
            t.expect(Blocking.eventually { await bench.link.status == .live }, "live")
            bench.provoke(2)
            t.expect(Blocking.eventually { await bench.link.lastSeq == 5 }, "two events after the state's three")
            t.expectEqual(bench.opened, 1, "one channel")
        },

        TestCase("A channel the machine ends is opened again, and resumes after what it held") { t in
            let bench = Bench()
            defer { bench.stop() }
            t.expect(Blocking.eventually { await bench.link.lastSeq == 3 }, "the state held")
            // Two changes the first channel never delivers, then it ends.
            bench.made = V1ReferenceFixtureShim.provoke(bench.source, count: 2, made: bench.made, at: bench.now)
            bench.channels.first?.end()
            t.expect(Blocking.eventually { await bench.link.lastSeq == 5 }, "the two missed events arrived")
            t.expectEqual(bench.opened, 2, "a second channel")
            t.expectEqual(bench.channels.last?.repliedTypes.contains("state"), false, "by replay, not a whole state")
        },

        TestCase("Silence past the threshold is declared old, and the channel replaced") { t in
            let bench = Bench()
            defer { bench.stop() }
            t.expect(Blocking.eventually { await bench.link.status == .live }, "live")
            let threshold = (try? Blocking.run { await bench.link.staleAfter }) ?? 35
            bench.clock.advance(threshold + 1)
            _ = try? Blocking.run { await bench.link.tick() }
            // The events reach the bench through a stream read by a task of its
            // own: what the link said is waited for, not assumed delivered.
            t.expect(Blocking.eventually { bench.saw { if case .stale = $0 { return true }; return false } }, "declared old")
            t.expect(Blocking.eventually { bench.opened == 2 }, "and replaced")
            t.expect(Blocking.eventually { await bench.link.isStale == false }, "fresh again once the new one answered")
        },

        TestCase("A link stopped while a channel is opening stays stopped, and closes what comes late") { t in
            // The actor lets `stop` in while the loop waits on `open`: the
            // channel that arrives after it must not bring the link back to life.
            let release = DispatchSemaphore(value: 0)
            let clock = ManualClock(), source = V1ReferenceFixtureShim.source()
            let made = Holder<MemoryChannel>()
            let link = V1Link(name: "test", pingInterval: 5, backoff: [0.01], tickEvery: nil, clock: { clock.now }) {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async { release.wait(); c.resume() }
                }
                let channel = MemoryChannel(source: source, clock: clock)
                made.set(channel)
                return channel
            }
            _ = try? Blocking.run { await link.start() }
            usleep(100_000)
            _ = try? Blocking.run { await link.stop() }
            release.signal()
            t.expect(Blocking.eventually(5) { made.value != nil }, "the late channel was made")
            usleep(200_000)
            t.expectEqual(try? Blocking.run { await link.status }, .stopped, "still stopped")
            t.expect(Blocking.eventually(5) { made.value?.isClosed == true }, "and the late channel closed")
        },

        TestCase("A link stopped while an attempt is failing stays stopped") { t in
            // The failure lands after `stop`: it must not turn into a wait for
            // the next attempt.
            let release = DispatchSemaphore(value: 0)
            let clock = ManualClock()
            let link = V1Link(name: "test", backoff: [0.3], tickEvery: nil, clock: { clock.now }) {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async { release.wait(); c.resume() }
                }
                throw NodeLinkError.refused("the channel")
            }
            _ = try? Blocking.run { await link.start() }
            usleep(100_000)
            _ = try? Blocking.run { await link.stop() }
            release.signal()
            usleep(200_000)
            t.expectEqual(try? Blocking.run { await link.status }, .stopped, "still stopped")
        },

        TestCase("A link stopped before its clock started has no clock running") { t in
            let ticks = Counter()
            let link = V1Link(name: "test", tickEvery: 0.02, clock: { ticks.bump(); return V1Fixtures.t0 }) {
                throw NodeLinkError.closed
            }
            _ = try? Blocking.run { await link.stop() }
            usleep(150_000)
            let after = ticks.value
            usleep(200_000)
            t.expectEqual(ticks.value, after, "the clock is not read any more")
        },
    ])
}

private final class Holder<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: T?
    var value: T? { lock.lock(); defer { lock.unlock() }; return held }
    func set(_ value: T) { lock.lock(); held = value; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

// MARK: - The bench: a link over channels to a service in memory

private final class Bench: @unchecked Sendable {
    let source: V1MemorySource
    let clock: ManualClock
    var made: Int
    var now: Date { clock.now }
    let link: V1Link
    private let lock = NSLock()
    private var opens: [MemoryChannel] = []
    private var seen: [V1Client.Event] = []

    init() {
        let clock = ManualClock(), source = V1ReferenceFixtureShim.source()
        self.clock = clock
        self.source = source
        made = V1ReferenceFixtureShim.provoke(source, count: 3, made: 0, at: clock.now)
        var register: (MemoryChannel) -> Void = { _ in }
        link = V1Link(name: "test", pingInterval: 5, backoff: [0.01], tickEvery: nil, clock: { clock.now }) {
            let channel = MemoryChannel(source: source, clock: clock)
            register(channel)
            return channel
        }
        register = { [weak self] channel in self?.adopt(channel) }
        let link = self.link
        Task.detached { [weak self] in
            for await event in link.events { self?.record(event) }
        }
        _ = try? Blocking.run { await link.start() }
    }

    var channels: [MemoryChannel] { lock.lock(); defer { lock.unlock() }; return opens }
    var opened: Int { channels.count }

    func provoke(_ count: Int) {
        made = V1ReferenceFixtureShim.provoke(source, count: count, made: made, at: clock.now)
        channels.last?.pump()
    }

    func saw(_ wanted: (V1Client.Event) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.contains(where: wanted)
    }

    func stop() { _ = try? Blocking.run { await self.link.stop() } }

    private func adopt(_ channel: MemoryChannel) { lock.lock(); opens.append(channel); lock.unlock() }
    private func record(_ event: V1Client.Event) { lock.lock(); seen.append(event); lock.unlock() }
}

/// A `V1Service` behind the channel protocol: what the link writes is answered
/// at once; `pump` delivers what the source did since.
private final class MemoryChannel: NodeByteChannel, @unchecked Sendable {
    let inbound: AsyncStream<[UInt8]>
    private let feed: AsyncStream<[UInt8]>.Continuation
    private let clock: ManualClock
    private let lock = NSLock()
    private var service: V1Service
    private var types: [String] = []
    private var closed = false

    init(source: V1Source, clock: ManualClock) {
        self.clock = clock
        service = V1Service(source: source, peer: V1Peer(device: "phone-1", role: .read))
        (inbound, feed) = AsyncStream.makeStream(of: [UInt8].self)
    }

    var repliedTypes: [String] { lock.lock(); defer { lock.unlock() }; return types }

    func write(_ bytes: [UInt8]) async throws {
        let now = clock.now
        let out = lock.withLock { service.receive(bytes, at: now) }
        deliver(out)
    }

    func pump() {
        lock.lock()
        let out = service.poll(at: clock.now)
        lock.unlock()
        deliver(out)
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func end() { feed.finish() }

    func close() async {
        lock.withLock { closed = true }
        feed.finish()
    }

    private func deliver(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        types += V1Fixtures.types(bytes)
        lock.unlock()
        feed.yield(bytes)
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = V1Fixtures.t0

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// The reference source of the conformance battery: the same rows the ssh
/// check serves from its container.
private enum V1ReferenceFixtureShim {
    static func source() -> V1MemorySource { V1ReferenceFixture.source(startedAt: V1Fixtures.t0) }
    static func provoke(_ source: V1MemorySource, count: Int, made: Int, at now: Date) -> Int {
        V1ReferenceFixture.provoke(source, count: count, made: made, at: now)
    }
}

private enum ChannelErrorFixture {
    static var alreadyClosed: Error { NodeLinkError.alreadyClosedForTests }
}

private extension Never {
    /// Suspends for ever, ignoring cancellation: the operation a deadline exists for.
    static func forever() async -> Never {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in Parked.keep(continuation) }
        fatalError("unreachable")
    }

    /// Answers after `seconds`, whatever happens to the task in the meantime.
    static func after<T>(_ seconds: TimeInterval, returning value: T) async -> T {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<T, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: value) }
        }
    }
}

/// Continuations that are never resumed, kept so that nothing reports them leaked.
private enum Parked {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [UnsafeContinuation<Void, Never>] = []
    static func keep(_ continuation: UnsafeContinuation<Void, Never>) { lock.lock(); held.append(continuation); lock.unlock() }
}
