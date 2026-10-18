import Foundation
import LampBoardCore

/// The pairing window (§2.4): one code, two minutes, used once, closed after
/// three wrong ones. While no window is open, the `pair` account has no
/// password at all.
public final class MacPairingWindow: @unchecked Sendable {

    public enum Attempt: Equatable, Sendable {
        case accepted
        case refused(String)
    }

    private let lock = NSLock()
    private var code: String?
    private var closesAt: Date?
    private var wrong = 0
    private var used = false
    private let lasts: TimeInterval
    private let maxWrong: Int

    public init(lasts: TimeInterval = MacBridge.pairingWindow, maxWrong: Int = MacBridge.maxWrongCodes) {
        self.lasts = lasts
        self.maxWrong = maxWrong
    }

    /// Opens a window with a new code, closing any other.
    public func open(at now: Date, code: String = MacPairingCode.make()) -> (code: String, closesAt: Date) {
        locked {
            self.code = code
            closesAt = now.addingTimeInterval(lasts)
            wrong = 0
            used = false
            return (code, closesAt!)
        }
    }

    public func close() {
        locked {
            code = nil
            closesAt = nil
        }
    }

    /// Whether a code would be taken now.
    public func isOpen(at now: Date) -> Bool {
        locked { code != nil && !used && wrong < maxWrong && (closesAt.map { now < $0 } ?? false) }
    }

    public var deadline: Date? { locked { closesAt } }

    /// One try of the code. The comparison takes the same time whatever it
    /// finds, and a right code after the window closed is still refused.
    public func attempt(_ given: String, at now: Date) -> Attempt {
        locked {
            guard let code, let closesAt else { return .refused("no pairing window is open") }
            if used { return .refused("this code was used already") }
            if wrong >= maxWrong { return .refused("the window closed after \(maxWrong) wrong codes") }
            if now >= closesAt { return .refused("the window closed") }
            let want = Array(code.utf8), got = Array(given.utf8)
            var difference = want.count == got.count ? 0 : 1
            for index in 0..<max(want.count, got.count) {
                difference |= Int((index < want.count ? want[index] : 0) ^ (index < got.count ? got[index] : 0))
            }
            if difference != 0 {
                wrong += 1
                return .refused("wrong code")
            }
            used = true
            return .accepted
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Failures before authentication, per address: each one waits longer before
/// its answer (§2.10, «ritardo crescente sugli errori»), up to a ceiling, and a
/// success forgives the address.
public final class MacAuthThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: (count: Int, last: Date)] = [:]
    private let base: TimeInterval
    private let ceiling: TimeInterval

    public init(base: TimeInterval = 0.25, ceiling: TimeInterval = 8) {
        self.base = base
        self.ceiling = ceiling
    }

    /// How long to hold the next answer to `address`.
    public func delay(for address: String, at now: Date) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = failures[address] else { return 0 }
        // Ten quiet minutes and the address starts again.
        if now.timeIntervalSince(entry.last) > 600 {
            failures[address] = nil
            return 0
        }
        return min(ceiling, base * pow(2, Double(entry.count - 1)))
    }

    public func failed(_ address: String, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        let count = (failures[address]?.count ?? 0) + 1
        failures[address] = (count, now)
        // A scan from many addresses must not grow this without end.
        if failures.count > 4096 { failures = failures.filter { now.timeIntervalSince($0.value.last) < 600 } }
    }

    public func succeeded(_ address: String) {
        lock.lock()
        defer { lock.unlock() }
        failures[address] = nil
    }
}
