import Foundation

/// Asynchronous code, waited for by a synchronous test.
///
/// The cases here are plain closures, and the code NodeLink runs is `async`.
/// This runs it in a detached task — never on the caller's actor, which may be
/// the main thread this call is about to block — and waits at most `seconds`.
public enum Blocking {

    public struct TimedOut: Error, CustomStringConvertible {
        public let seconds: TimeInterval
        public var description: String { "still running after \(seconds) s" }
    }

    public static func run<T>(_ seconds: TimeInterval = 30, _ operation: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success, let result = box.result else {
            throw TimedOut(seconds: seconds)
        }
        return try result.get()
    }

    /// `true` as soon as `condition` holds, `false` if it never did within `seconds`.
    public static func eventually(_ seconds: TimeInterval = 10, _ condition: @escaping () async -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? run(seconds) { await condition() }) == true { return true }
            usleep(10_000)
        }
        return false
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}
