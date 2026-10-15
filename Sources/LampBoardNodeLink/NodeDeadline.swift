import Foundation
import NIOCore

/// What went wrong between the phone and a machine, in words the app can show.
public enum NodeLinkError: Error, Equatable, CustomStringConvertible {
    /// The machine presented another key than the one pinned. Nothing was sent.
    case hostKeyMismatch(presented: String, expected: String)
    /// The machine refused the key, or the channel.
    case refused(String)
    /// An operation did not finish within its deadline.
    case timedOut(String, seconds: TimeInterval)
    /// The connection or the channel is already closed.
    case closed
    /// A key that cannot be read.
    case badKey(String)
    /// The network or the ssh layer failed.
    case failed(String)

    public var description: String {
        switch self {
        case .hostKeyMismatch(let presented, let expected):
            return "host key mismatch: the machine presented \(presented), pinned is \(expected)"
        case .refused(let what): return "refused: \(what)"
        case .timedOut(let what, let seconds): return "\(what) took longer than \(Int(seconds)) s"
        case .closed: return "the connection is closed"
        case .badKey(let why): return "bad key: \(why)"
        case .failed(let why): return why
        }
    }

    /// `true` for the errors that only say the other side closed first.
    ///
    /// Citadel's channels throw `ChannelError.alreadyClosed` when the machine
    /// ended the channel before we did — measured at the end of every attach in
    /// S-C. That is how a channel normally ends, not a failure.
    public static func isNormalEnd(_ error: Error) -> Bool {
        if let channel = error as? ChannelError {
            return channel == .alreadyClosed || channel == .eof || channel == .outputClosed
        }
        return false
    }

    /// What Citadel throws when the machine closed first, for the tests that
    /// have no NIO of their own.
    static var alreadyClosedForTests: Error { ChannelError.alreadyClosed }
}

/// How long each operation may take. Every wait has an end: an ssh call that
/// never returns is the classic way for an app to hang believing it is still
/// connecting (Citadel's `openSFTP` waits for ever against a forced command, E12).
public struct NodeDeadlines: Sendable {
    public var connect: TimeInterval
    public var open: TimeInterval
    public var write: TimeInterval
    public var close: TimeInterval
    public var command: TimeInterval

    public init(connect: TimeInterval = 10, open: TimeInterval = 10, write: TimeInterval = 10,
                close: TimeInterval = 5, command: TimeInterval = 30) {
        self.connect = connect
        self.open = open
        self.write = write
        self.close = close
        self.command = command
    }

    public static let standard = NodeDeadlines()
}

/// Runs an operation against a clock, and leaves when the clock wins.
///
/// Cancelling a task is not enough: a future deep in NIO that ignores
/// cancellation keeps its caller waiting (S-C v2 had to race `openSFTP` against
/// a timer). So the caller is answered by whichever finishes first, the
/// operation is cancelled and `expired` runs (typically: close the connection
/// under it), and a result that arrives after the deadline goes to `late`,
/// which must dispose of it — a connection made too late is closed, not leaked.
enum NodeDeadline {

    static func run<T>(
        _ seconds: TimeInterval,
        _ what: String,
        expired: @escaping () -> Void = {},
        late: @escaping (T) -> Void = { _ in },
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) } else { late(value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard gate.claim() else { return }
                work.cancel()
                expired()
                continuation.resume(throwing: NodeLinkError.timedOut(what, seconds: seconds))
            }
        }
    }

    /// Lets exactly one of the two racers answer.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
