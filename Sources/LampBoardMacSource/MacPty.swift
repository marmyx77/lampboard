#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// A terminal the Mac opens for the phone (§2.6, S-S): `forkpty`, then `execve`
/// of exactly the argument list it was given, in the environment it was given.
///
/// Everything the child needs is prepared before the fork; after it, only calls
/// that are safe in a forked child: signals back to their defaults, every
/// descriptor above the three standard ones closed (the server's listening
/// sockets must not live on in tmux), `execve`. One thread reads the master and
/// waits for each write into the channel before reading on: the ssh window is
/// the back-pressure, nothing piles up in memory.
public final class MacPty: @unchecked Sendable {

    public let pid: pid_t
    private let master: Int32
    private let writes = DispatchQueue(label: "lampboard.mac-pty.write")
    private let lock = NSLock()
    private var ended = false

    /// Starts `argv` on a new terminal of `columns` × `rows`; `nil` when the
    /// system would not give one.
    public init?(argv: [String], environment: [String], directory: String? = nil, columns: Int, rows: Int) {
        guard let executable = argv.first, executable.hasPrefix("/") else { return nil }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup($0) } + [nil]
        let cPath = strdup(executable)
        let cDirectory = directory.map { strdup($0) }
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
            free(cPath)
            cDirectory.map { free($0) }
        }
        let highest = min(Int32(getdtablesize()), 65536)
        var masterDescriptor: Int32 = -1
        let child = forkpty(&masterDescriptor, nil, nil, &size)
        if child < 0 { return nil }
        if child == 0 {
            var number: Int32 = 1
            while number < 32 {
                if number != SIGKILL && number != SIGSTOP { _ = signal(number, SIG_DFL) }
                number += 1
            }
            var empty = sigset_t()
            sigemptyset(&empty)
            _ = sigprocmask(SIG_SETMASK, &empty, nil)
            var descriptor: Int32 = 3
            while descriptor < highest { _ = close(descriptor); descriptor += 1 }
            if let directory = cDirectory ?? nil { _ = chdir(directory) }
            cArguments.withUnsafeBufferPointer { arguments in
                cEnvironment.withUnsafeBufferPointer { environment in
                    _ = execve(cPath!, arguments.baseAddress!, environment.baseAddress!)
                }
            }
            _exit(127)
        }
        master = masterDescriptor
        pid = child
        MacPty.living.insert(child)
    }

    /// Reads until the child's side closes. `send` must not return until the
    /// bytes are taken; `done` is told the exit status.
    public func start(send: @escaping @Sendable ([UInt8]) -> Void, done: @escaping @Sendable (Int32) -> Void) {
        let master = self.master, pid = self.pid
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { send(Array(buffer[0..<count])) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            MacPty.living.remove(pid)
            self?.markEnded()
            close(master)
            let exited = (status & 0x7f) == 0
            done(exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        }
        thread.name = "lampboard.mac-pty.read"
        thread.start()
    }

    /// What the phone typed.
    public func write(_ bytes: [UInt8]) {
        guard !isEnded else { return }
        let master = self.master
        writes.async {
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Foundation.write(master, $0.baseAddress, $0.count) }
                if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { return }
            }
        }
    }

    /// `window-change` from the phone.
    public func resize(columns: Int, rows: Int) {
        guard !isEnded else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = MacPtySize.set(master, &size)
    }

    /// The channel closed: the client hangs up, as when a terminal closes.
    public func hangUp() {
        guard !isEnded else { return }
        kill(pid, SIGHUP)
    }

    private var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    private func markEnded() {
        lock.lock()
        ended = true
        lock.unlock()
    }

    /// Every child still running, hung up when the server stops: none outlives it.
    public static let living = PidSet()

    public final class PidSet: @unchecked Sendable {
        private let lock = NSLock()
        private var pids = Set<pid_t>()

        func insert(_ pid: pid_t) { lock.lock(); pids.insert(pid); lock.unlock() }
        func remove(_ pid: pid_t) { lock.lock(); pids.remove(pid); lock.unlock() }

        public var all: Set<pid_t> {
            lock.lock()
            defer { lock.unlock() }
            return pids
        }

        public func hangUpAll() {
            for pid in all { kill(pid, SIGHUP) }
        }
    }
}

/// `TIOCSWINSZ`, whose `ioctl` is imported differently on each system.
enum MacPtySize {
    static func set(_ descriptor: Int32, _ size: inout winsize) -> Int32 {
        #if canImport(Darwin)
        return ioctl(descriptor, TIOCSWINSZ, &size)
        #else
        return ioctl(descriptor, UInt(TIOCSWINSZ), &size)
        #endif
    }
}
