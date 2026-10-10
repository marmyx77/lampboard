import Foundation

/// How long the main thread goes without answering, measured from outside it:
/// a thread of its own asks the main queue for a turn every tenth of a second
/// and times the answer. A stall the person sees as the spinning cursor is a
/// number here, and a test can fail on it (10 October 2026: a README in the
/// Hub held the main thread for tens of seconds, and nothing measured it).
///
/// Runs only on a fake home or with the debug log on.
final class MainThreadWatch: @unchecked Sendable {

    static let shared = MainThreadWatch()

    /// A wait longer than this is a stall, and goes to the debug log.
    static let stallMs = 250.0

    private let lock = NSLock()
    private var longestMs = 0.0
    private var stalls = 0
    private var started = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in loop() }
        thread.name = "lampboard.main-watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The longest wait and the stalls since the last reset.
    var snapshot: (longestMs: Double, stalls: Int) {
        lock.lock(); defer { lock.unlock() }
        return (longestMs, stalls)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        longestMs = 0
        stalls = 0
    }

    private func loop() {
        while true {
            let asked = DispatchTime.now().uptimeNanoseconds
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            answered.wait()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - asked) / 1_000_000
            lock.lock()
            longestMs = max(longestMs, ms)
            if ms > Self.stallMs { stalls += 1 }
            lock.unlock()
            if ms > Self.stallMs { Diagnostics.log("main thread: stalled \(Int(ms)) ms") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
