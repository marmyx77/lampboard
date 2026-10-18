import Foundation
import LampBoardCore
import LampBoardMacSource

/// The Hub's terminals on background sessions, offered to the Mac's bridge
/// (W5, §2.6): a phone that asks for a job the Hub has open shares that
/// terminal, and no second `claude attach` is ever started (D130).
///
/// Read by the server's threads, written on the main actor: a lock, and every
/// touch of a surface sent to the main queue.
final class HubShares: MacHubTerminals, @unchecked Sendable {
    private let lock = NSLock()
    private var open: [String: HubShare] = [:]

    @MainActor
    func register(job: String, surface: LiveSurface) {
        let share = HubShare(surface: surface)
        lock.lock()
        let previous = open.updateValue(share, forKey: job)
        lock.unlock()
        previous?.hubEnded()
    }

    @MainActor
    func unregister(job: String) {
        lock.lock()
        let share = open.removeValue(forKey: job)
        lock.unlock()
        share?.hubEnded()
    }

    func share(job: String) -> MacSharedTerminal? {
        lock.lock()
        defer { lock.unlock() }
        return open[job]
    }
}

/// One Hub terminal as the bridge sees it.
final class HubShare: MacSharedTerminal, @unchecked Sendable {
    private weak var surface: LiveSurface?
    private let lock = NSLock()
    private var ended: (@Sendable () -> Void)?

    @MainActor
    init(surface: LiveSurface) { self.surface = surface }

    func start(send: @escaping @Sendable ([UInt8]) -> Void, ended: @escaping @Sendable () -> Void) {
        lock.lock()
        self.ended = ended
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let surface = self?.surface, surface.isRunning else { return ended() }
                // What the Hub shows now, then everything as it comes.
                send(Array(("\u{1b}[2J\u{1b}[H" + surface.screenText(lines: 60).replacingOccurrences(of: "\n", with: "\r\n")).utf8))
                surface.onOutput = { bytes in send(bytes) }
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.surface?.type(bytes) }
        }
    }

    func stop() {
        lock.lock()
        ended = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.surface?.onOutput = nil }
        }
    }

    /// The Hub's terminal went: the phone's channel ends with it.
    func hubEnded() {
        lock.lock()
        let ended = self.ended
        self.ended = nil
        lock.unlock()
        ended?()
    }
}
