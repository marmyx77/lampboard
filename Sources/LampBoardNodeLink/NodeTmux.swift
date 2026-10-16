import Foundation
import LampBoardCore

/// A terminal attached to a tmux session by the rule of Q7 (`TmuxSizeRule`,
/// D176): the bytes without the mark the attach prints, and the pid of this
/// terminal's own tmux client, which the background rule needs.
public final class TmuxTerminal: NodeByteChannel, @unchecked Sendable {
    public let terminal: NodeTerminal
    public let session: String
    public let role: TmuxSizeRule.Role
    public let inbound: AsyncStream<[UInt8]>

    private let lock = NSLock()
    private var pid: Int?
    private var pump: Task<Void, Never>?

    init(_ terminal: NodeTerminal, session: String, role: TmuxSizeRule.Role) {
        self.terminal = terminal
        self.session = session
        self.role = role
        let (stream, feed) = AsyncStream.makeStream(of: [UInt8].self)
        inbound = stream
        pump = Task { [weak self] in
            var mark = TmuxClientMark()
            for await chunk in terminal.inbound {
                let passed = mark.pass(chunk)
                if let found = mark.pid { self?.found(found) }
                if !passed.isEmpty { feed.yield(passed) }
            }
            let rest = mark.finish()
            if !rest.isEmpty { feed.yield(rest) }
            feed.finish()
        }
    }

    deinit { pump?.cancel() }

    /// The pid of this terminal's tmux client, once the mark has arrived.
    public var clientPid: Int? { lock.lock(); defer { lock.unlock() }; return pid }

    /// Waits up to `seconds` for the client's pid.
    public func clientPid(within seconds: TimeInterval) async -> Int? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let pid = clientPid { return pid }
            if terminal.isEnded { return clientPid }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return clientPid
    }

    public func write(_ bytes: [UInt8]) async throws { try await terminal.write(bytes) }

    public func resize(_ size: TerminalSize) async throws { try await terminal.resize(size) }

    public func close() async { await terminal.close() }

    private func found(_ value: Int) {
        lock.lock()
        pid = value
        lock.unlock()
    }
}

@available(macOS 15.0, *)
extension ActionConnection {

    /// A terminal on tmux's `session`, by the rule of Q7: `.takesSize` for the
    /// phone in front, `.watches` for the iPad that looks without resizing.
    public func attachTmux(session: String, role: TmuxSizeRule.Role, size: TerminalSize,
                           server: TmuxSizeRule.Server = .default) async throws -> TmuxTerminal {
        guard let command = TmuxSizeRule.attach(session: session, role: role, server: server) else {
            throw NodeLinkError.failed("not a tmux session name: \(session)")
        }
        let terminal = try await openTerminal(command: command, size: size)
        return TmuxTerminal(terminal, session: session, role: role)
    }

    /// The background rule (call it inside `beginBackgroundTask`): the clients
    /// with these pids let go of the size and detach, so the window goes back to
    /// the device used last. Also what to run before attaching again, with the
    /// pids of this device's clients from before.
    public func releaseTmuxSize(clients pids: [Int], server: TmuxSizeRule.Server = .default) async throws -> TmuxSizeRule.Background {
        let result = try await run(TmuxSizeRule.background(clients: pids, server: server))
        return TmuxSizeRule.parseBackground(result.output)
    }

    /// The watching iPad takes the size: its client drops `ignore-size`; a key
    /// from it then makes the window its own.
    public func takeTmuxSize(client pid: Int, server: TmuxSizeRule.Server = .default) async throws -> Bool {
        try await run(TmuxSizeRule.takeSize(client: pid, server: server)).output.hasPrefix("taken ")
    }

    /// The server's clients, with their size and whether they ignore it.
    public func tmuxClients(server: TmuxSizeRule.Server = .default) async throws -> [TmuxClient] {
        TmuxSizeRule.parseClients(try await run(TmuxSizeRule.clients(server: server)).output)
    }

    /// What a `ProbeLink` runs its look with, on this connection.
    public var probeRunner: ProbeLink.Runner {
        { [self] command in try await self.run(command, limit: 8 << 20) }
    }

    /// One look at the machine's lights and tmux sessions, read-only (D176).
    /// `nil` when the machine did not give an answer that can be read.
    public func probeLights(name: String, server: TmuxSizeRule.Server = .default,
                            at now: Date = Date()) async throws -> V1ProbeReading? {
        let result = try await run(V1ProbeReading.command(server: server), limit: 8 << 20)
        return V1ProbeReading.parse(result.output, host: name, at: now)
    }
}
