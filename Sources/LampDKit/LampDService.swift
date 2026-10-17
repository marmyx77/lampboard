import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The service: one look at the files every few seconds on the main loop, and
/// the `v1` connections the read key's command brings in through a Unix socket.
///
/// The main loop is the only thing that tells systemd it is alive
/// (`WATCHDOG=1`, ADR-65 point 6, E10). A loop that stops — a look that never
/// returns, a lock never released — stops the heartbeat, and systemd kills the
/// process and starts it again; a heartbeat from a thread of its own would keep
/// a frozen service "alive" for ever, which is the failure this machine is known
/// for (`~/AGENTS.md`: alive, on an old state).
///
/// Connections never hold the loop: each has a thread that reads, and a thread
/// that writes from a queue of its own, so a phone on a slow network fills its
/// own queue — and is dropped past a bound, to come back with `since` — rather
/// than the loop's.
public final class LampDService: @unchecked Sendable {

    public let paths: LampDPaths
    public let config: LampDConfig
    public let source: NodeSource
    private let probe: LocalProbe
    private let log: LampDLog
    /// The checks' hooks (`LAMPD_TEST_HOOKS=1`): the file that stops the loop on
    /// purpose, for the watchdog's bite. Never set by the unit in the repository.
    private let testHooks: Bool

    private let state = NSCondition()
    private var stopping = false
    private var lookRequested = false
    private var looks = 0
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var listener: Int32 = -1

    public init(paths: LampDPaths, config: LampDConfig, version: String, log: LampDLog,
                probeEnvironment: [String: String?] = [:], testHooks: Bool = false) {
        self.paths = paths
        self.config = config
        self.log = log
        self.testHooks = testHooks
        probe = LocalProbe(paths: paths, environment: probeEnvironment)
        source = NodeSource(identity: config.identity, mode: .live, paths: paths, version: version, startedAt: Date())
    }

    /// Runs until SIGTERM or SIGINT; the exit code.
    public func run() -> Int32 {
        do {
            try LampDPaths.makeDirectory(paths.stateDirectory)
            try LampDPaths.makeDirectory(paths.runtimeDirectory)
        } catch {
            log.write("cannot prepare its folders: \(error)")
            return 1
        }
        guard let fd = UnixSocket.listen(paths.socket) else {
            log.write("cannot listen on \(paths.socket): \(String(cString: strerror(errno)))")
            return 1
        }
        listener = fd
        stopOnSignals()
        // One look before saying ready, so that the first phone gets rows; the
        // socket is bound before READY=1 (E10).
        lookOnce()
        SystemdNotify.send("READY=1\nSTATUS=serving \(paths.socket)")
        log.write("serving \(paths.socket) as \(config.name)")
        Thread.detachNewThread { [self] in acceptLoop() }
        Thread.detachNewThread { [self] in pollLoop() }
        if config.allowance { LampDUsage.refresh(paths: paths, name: config.name) }
        mainLoop()
        shutDown()
        return 0
    }

    // MARK: - The main loop

    private func mainLoop() {
        let beat = min(config.probeInterval, (SystemdNotify.watchdogInterval ?? 30) / 3)
        var nextLook = Date().addingTimeInterval(config.probeInterval)
        while true {
            state.lock()
            while !stopping && !lookRequested && Date() < nextLook {
                _ = state.wait(until: min(nextLook, Date().addingTimeInterval(beat)))
                state.unlock()
                // A heartbeat at least every third of the watchdog's interval,
                // from this loop and nowhere else.
                SystemdNotify.send("WATCHDOG=1")
                state.lock()
            }
            if stopping {
                state.unlock()
                return
            }
            lookRequested = false
            state.unlock()
            if testHooks, FileManager.default.fileExists(atPath: paths.blockLoopFile) {
                // The watchdog's bite: the loop stops for ever, the process lives.
                try? FileManager.default.removeItem(atPath: paths.blockLoopFile)
                log.write("the loop stops here on purpose (\(paths.blockLoopFile))")
                while true { sleep(3600) }
            }
            lookOnce()
            SystemdNotify.send("WATCHDOG=1")
            nextLook = Date().addingTimeInterval(config.probeInterval)
        }
    }

    private func lookOnce() {
        let look = probe.look()
        if let problem = look.problem { log.write("look: \(problem)") }
        source.absorb(look)
        state.lock()
        looks += 1
        state.broadcast()
        state.unlock()
        wakePoller()
    }

    /// Asks the loop for a look now and waits for it, for at most `timeout`.
    func requestLook(timeout: TimeInterval) -> Bool {
        state.lock()
        defer { state.unlock() }
        let target = looks + 1
        lookRequested = true
        state.broadcast()
        let deadline = Date().addingTimeInterval(timeout)
        while looks < target && !stopping {
            if !state.wait(until: deadline) { return false }
        }
        return looks >= target
    }

    // MARK: - Stopping

    private var signalSources: [DispatchSourceSignal] = []

    private func stopOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalSources.append(source)
        }
    }

    public func stop() {
        state.lock()
        stopping = true
        state.broadcast()
        state.unlock()
    }

    /// Every connection is told `bye` and closed (E4, E10: without it a phone
    /// attached held every restart for 90 s), then the socket goes.
    private func shutDown() {
        SystemdNotify.send("STOPPING=1")
        let open = state.synchronized { Array(connections.values) }
        for connection in open { connection.close(reason: "lampd is stopping") }
        let deadline = Date().addingTimeInterval(2)
        for connection in open { connection.waitUntilWritten(before: deadline) }
        if listener >= 0 {
            shutdown(listener, Int32(SHUT_RDWR))
            close(listener)
        }
        unlink(paths.socket)
        log.write("stopped")
    }

    // MARK: - Connections

    private func acceptLoop() {
        while let fd = UnixSocket.accept(listener) {
            Thread.detachNewThread { [self] in handle(fd) }
        }
    }

    private func handle(_ fd: Int32) {
        guard let header = UnixSocket.readLine(fd) else { close(fd); return }
        let words = header.split(separator: " ").map(String.init)
        switch words.first {
        case "v1":
            guard words.count >= 3, let role = V1Role(rawValue: words[2]) else { close(fd); return }
            let asked = words.count >= 4 ? String(decoding: Data(base64Encoded: words[3]) ?? Data(), as: UTF8.self) : ""
            serve(fd, peer: V1Peer(device: words[1], role: role), asked: asked)
        case "look":
            let done = requestLook(timeout: 20)
            UnixSocket.sendAll(fd, Array("\(done ? "ok" : "late") \(source.status(at: Date()).seq)\n".utf8))
            close(fd)
        case "status":
            let report = LampDStatus.report(source: source, config: config, paths: paths, at: Date())
            UnixSocket.sendAll(fd, Array(((try? report.json()) ?? "{}").utf8) + [0x0A])
            close(fd)
        default:
            close(fd)
        }
    }

    private func serve(_ fd: Int32, peer: V1Peer, asked: String) {
        // What the client asked to run, when sshd forced this command instead:
        // a datum, logged and never run (E10).
        log.write("connection device=\(peer.device) role=\(peer.role.rawValue) asked=\(asked.isEmpty ? "-" : asked)")
        DevicesStore(paths: paths).seen(peer.device, at: Date())
        let connection = Connection(fd: fd, service: V1Service(source: source, peer: peer))
        let key = ObjectIdentifier(connection)
        let accepted: Bool = state.synchronized {
            guard !stopping else { return false }
            connections[key] = connection
            return true
        }
        guard accepted else {
            connection.close(reason: "lampd is stopping")
            connection.waitUntilWritten(before: Date().addingTimeInterval(1))
            close(fd)
            return
        }
        Thread.detachNewThread { connection.writeLoop() }
        while let bytes = UnixSocket.readSome(fd) {
            connection.receive(bytes)
            if connection.isClosed { break }
        }
        connection.finish()
        state.synchronized { connections[key] = nil }
        connection.waitUntilWritten(before: Date().addingTimeInterval(1))
        close(fd)
    }

    private let pollSignal = DispatchSemaphore(value: 0)

    private func wakePoller() { pollSignal.signal() }

    /// New events and pings for every connection, ten times a second and at
    /// once after a look.
    private func pollLoop() {
        while !state.synchronized({ stopping }) {
            _ = pollSignal.wait(timeout: .now() + 0.1)
            for connection in state.synchronized({ Array(connections.values) }) { connection.poll() }
        }
    }
}

/// One `v1` connection: its service, and what is waiting to be written.
final class Connection: @unchecked Sendable {
    /// Past this much unwritten, the client is dropped: it comes back with
    /// `since` and loses nothing, and the service keeps no unbounded queue.
    static let maxQueued = 8 * 1024 * 1024

    let fd: Int32
    private var service: V1Service
    private let condition = NSCondition()
    private var queue: [[UInt8]] = []
    private var queued = 0
    private var ending = false
    private var writerDone = false

    init(fd: Int32, service: V1Service) {
        self.fd = fd
        self.service = service
    }

    var isClosed: Bool { condition.synchronized { service.isClosed } }

    func receive(_ bytes: [UInt8]) {
        condition.lock()
        let out = service.receive(bytes, at: Date())
        enqueue(out)
        if service.isClosed { ending = true }
        condition.broadcast()
        condition.unlock()
    }

    func poll() {
        condition.lock()
        guard !ending else { condition.unlock(); return }
        enqueue(service.poll(at: Date()))
        condition.broadcast()
        condition.unlock()
    }

    func close(reason: String) {
        condition.lock()
        enqueue(service.close(reason: reason))
        ending = true
        condition.broadcast()
        condition.unlock()
    }

    /// The reader saw the end: nothing more is written.
    func finish() {
        condition.lock()
        ending = true
        condition.broadcast()
        condition.unlock()
    }

    /// Under the lock.
    private func enqueue(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for piece in V1Frame.pieces(bytes) {
            queue.append(piece)
            queued += piece.count
        }
        if queued > Self.maxQueued {
            queue = []
            queued = 0
            ending = true
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    func writeLoop() {
        while true {
            condition.lock()
            while queue.isEmpty && !ending { condition.wait() }
            let pieces = queue
            queue = []
            queued = 0
            let end = ending
            condition.unlock()
            for piece in pieces where !UnixSocket.sendAll(fd, piece) {
                condition.synchronized { ending = true }
                break
            }
            if end && condition.synchronized({ queue.isEmpty }) { break }
        }
        shutdown(fd, Int32(SHUT_RDWR))
        condition.synchronized {
            writerDone = true
            condition.broadcast()
        }
    }

    func waitUntilWritten(before deadline: Date) {
        condition.lock()
        while !writerDone {
            if !condition.wait(until: deadline) { break }
        }
        condition.unlock()
    }
}

extension NSCondition {
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Where `lampd` says what it did: standard error for the service (systemd
/// keeps it in the journal), a file in its state folder for the forced command,
/// whose standard error would go to the phone.
public struct LampDLog: Sendable {
    public let file: String?

    public init(file: String?) { self.file = file }

    public func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) lampd[\(getpid())]: \(line)\n"
        guard let file else {
            FileHandle.standardError.write(Data(text.utf8))
            return
        }
        // Kept small: a forced command runs on every connection of every phone.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int, size > 1_048_576 {
            try? FileManager.default.removeItem(atPath: file + ".1")
            try? FileManager.default.moveItem(atPath: file, toPath: file + ".1")
        }
        if !FileManager.default.fileExists(atPath: file) {
            _ = FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
