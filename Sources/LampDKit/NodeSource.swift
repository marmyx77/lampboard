import Foundation
import LampBoardCore

/// This machine as a `v1` source: its rows, read from Claude Code's files with
/// the Core's rules; its journal; the person's choices; its paired devices.
///
/// The same type serves both ways a node answers (`V1ServingMode`): inside the
/// service, with the journal and the choices kept on disk, and inside a forced
/// command when the service is not running, with a journal that lives as long
/// as the connection. Only `mode` and where the journal lives differ, so the
/// lights the phone sees do not depend on which one answered.
///
/// Thread-safe: looks arrive on the main loop while connections are served on
/// threads of their own.
public final class NodeSource: V1Source, @unchecked Sendable {

    public let identity: V1SourceIdentity
    public let mode: V1ServingMode
    public let paths: LampDPaths
    private let version: String
    private let startedAt: Date
    private let journal: NodeJournal
    private let preferencesFile: PreferencesFile
    private var preferences: RowPreferences
    private let devicesStore: DevicesStore
    private let lock = NSLock()
    private var lastProbeAt: Date?
    private var lastProblem: String?
    /// The rows of the last look, before the person's choices: a change of a
    /// choice is applied to them at once, without waiting for the next look.
    private var fresh: [V1Row] = []
    /// Where each session's conversation started, for its transcript.
    private var cwds: [String: String] = [:]
    /// When each device said it was in use (`focus`): what decides which one
    /// rings (Q9, W4).
    public private(set) var focusedAt: [String: Date] = [:]
    /// The notifications: registrations in every mode, sending only in the
    /// service's (`NodePushes.relay`).
    public let pushes: NodePushes
    /// What the hooks say, once the service holds their port (W5). Empty, and
    /// changing nothing, until a hook speaks.
    public let hooks: NodeHooks
    private let macFile: MacStateFile
    /// When `lampd mac-link` last asked: the Mac's link is up (Q8).
    private var macLinkSeenAt: Date?

    public init(identity: V1SourceIdentity, mode: V1ServingMode, paths: LampDPaths, version: String,
                startedAt: Date, retention: Int = 1000, relay: RelayClient? = nil, hooks: NodeHooks = NodeHooks(),
                log: @escaping (String) -> Void = { _ in }) {
        self.identity = identity
        self.mode = mode
        self.paths = paths
        self.version = version
        self.startedAt = startedAt
        // The state folder holds the journal and the choices, in both modes:
        // a forced command reading files keeps the person's choices too.
        try? LampDPaths.makeDirectory(paths.stateDirectory)
        journal = NodeJournal(directory: mode == .live ? paths.stateDirectory : nil, retention: retention,
                              newName: { (mode == .files ? "files-" : "lampd-") + String(UInt64.random(in: 0...UInt64.max), radix: 36) })
        preferencesFile = PreferencesFile(path: paths.preferencesFile)
        preferences = preferencesFile.load()
        devicesStore = DevicesStore(paths: paths)
        pushes = NodePushes(identity: identity, paths: paths, relay: mode == .live ? relay : nil, log: log)
        self.hooks = hooks
        macFile = MacStateFile(path: paths.macStateFile)
    }

    // MARK: - Looks

    /// What one look found. A look that failed keeps the rows as they were and
    /// says why in `status`: an empty column for "could not look" is the lie
    /// D21 forbids.
    public func absorb(_ look: LocalProbe.Look) {
        locked {
            lastProbeAt = look.at
            lastProblem = look.problem
            guard let reading = look.reading else { return }
            hooks.reconcile(with: reading.report.sessions, at: look.at)
            fresh = NodeRows.rows(from: reading, jobs: look.jobs, identity: identity, at: look.at)
            cwds = Dictionary(reading.report.sessions.map { ($0.sessionId, $0.cwd) }, uniquingKeysWith: { first, _ in first })
            // The choices are read again at each look: the service and a forced
            // command reading files may each have written one.
            preferences = preferencesFile.load()
            publish(at: look.at)
            journal.confirm(at: look.at)
            journal.flush()
        }
        // Outside the lock: sealing is quick, but a connection's `hello` must
        // never wait on it.
        pushes.after(rows: currentRows, at: look.at, macHere: macHere(at: look.at))
    }

    /// A hook, a report of the mod, a question the Mac holds or a line from
    /// the Mac changed a row: published now, not at the next look, and the
    /// notifications decided on it.
    public func changed(at now: Date) {
        locked {
            preferences = preferencesFile.load()
            publish(at: now)
            journal.flush()
        }
        pushes.after(rows: currentRows, at: now, macHere: macHere(at: now))
    }

    // MARK: - The Mac (`lampd mac-link`)

    /// `lampd mac-link` asked how the service is: the Mac's link is up.
    public func macLinkSeen(at now: Date) { locked { macLinkSeenAt = now } }

    /// Whether the person is at the Mac (Q8): then the Mac's banners ring for
    /// these rows, and the phone does not.
    public func macHere(at now: Date) -> Bool {
        macFile.load().isHere(at: now, linkSeenAt: locked { macLinkSeenAt })
    }

    public func macDescription(at now: Date) -> String {
        macFile.load().describe(at: now, linkSeenAt: locked { macLinkSeenAt })
    }

    /// A line from the Mac, carried out: kept on disk like a phone's choice,
    /// and a read or an unread told to the hooks' state too.
    public func takeFromMac(_ line: MacToNode, at now: Date) -> Result<MacToNode, LampDError> {
        let result = MacLines.apply(line, paths: paths)
        if case .success = result, let command = line.command, let id = command.session {
            if command.action == .markSeen { hooks.markSeen(id, at: now) }
            if command.action == .markUnread { hooks.markUnread(id, at: now) }
        }
        changed(at: now)
        return result
    }

    /// The rows as the column shows them now.
    public var currentRows: [V1Row] { locked { journal.rows.values.sorted { $0.id < $1.id } } }

    /// The rows the column shows, made events: one per row that changed, one
    /// per row that went.
    private func publish(at now: Date) {
        let shown = NodeRows.shown(hooks.overlaid(fresh, at: now), preferences: preferences)
        let ids = Set(shown.map(\.id))
        for id in journal.rows.keys.sorted() where !ids.contains(id) { journal.remove(id: id, at: now) }
        for row in shown where !Self.sameOnTheWire(journal.rows[row.id], row) { journal.upsert(row, at: now) }
    }

    /// Two rows a phone cannot tell apart: the same bytes on the wire. The
    /// journal keeps its rows as the wire writes them, whole seconds, and a
    /// transcript's time has milliseconds: compared as values, every row would
    /// be a change after each restart.
    static func sameOnTheWire(_ a: V1Row?, _ b: V1Row) -> Bool {
        guard let a else { return false }
        if a == b { return true }
        let encoder = V1Codec.encoder()
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    public var lastProbe: (at: Date?, problem: String?) { locked { (lastProbeAt, lastProblem) } }

    // MARK: - V1Source

    public func status(at now: Date) -> V1SourceStatus {
        locked {
            V1SourceStatus(
                version: version, startedAt: startedAt, binaryModifiedAt: LampDBinary.modifiedAt,
                configModifiedAt: LampDBinary.modified(paths.configFile), journal: journal.name, seq: journal.seq,
                lastEventAt: journal.lastEventAt, lastProbeAt: lastProbeAt, relay: pushes.relayHealth, mode: mode,
                settings: macFile.load().settings
            )
        }
    }

    public func snapshot(at now: Date) -> V1State { locked { journal.snapshot(source: identity, at: now) } }

    public func events(after seq: Int) -> V1Replay { locked { journal.events(after: seq) } }

    /// Read outside the lock: a long conversation must not hold every other
    /// connection's events while it is read.
    public func transcript(session: String, limit: Int) -> V1Transcript? {
        let cwd: String?? = locked { journal.rows[session] == nil ? nil : .some(cwds[session]) }
        guard let cwd, let path = NodeTranscripts.locate(session: session, cwd: cwd, claudeDirectory: paths.claudeDirectory)
        else { return nil }
        return NodeTranscripts.read(session: session, path: path, limit: limit)
    }

    public func perform(_ command: V1Command, by peer: V1Peer, at now: Date) -> V1Failure? {
        locked {
            if command.action == .focus {
                focusedAt[peer.device] = now
                pushes.used(by: peer.device, session: command.session, at: now)
                return nil
            }
            if let id = command.session, journal.rows[id] == nil {
                return V1Failure(.notFound, "no row \(id)")
            }
            if let id = command.session {
                if command.action == .markSeen { hooks.markSeen(id, at: now) }
                if command.action == .markUnread { hooks.markUnread(id, at: now) }
            }
            do {
                preferences = try preferencesFile.update { $0.apply(command, at: now) }
            } catch {
                return V1Failure(.unavailable, "the choice could not be kept: \(error)")
            }
            publish(at: now)
            journal.flush()
            return nil
        }
    }

    /// Kept on disk for the service, whichever process took it (§2.8).
    public func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> Result<V1PushAccepted, V1Failure> {
        pushes.register(registration, device: peer.device, at: now)
    }

    public func away(for peer: V1Peer, at now: Date) -> String? {
        mode == .live ? pushes.away(for: peer.device, rows: currentRows, at: now) : nil
    }

    public func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure> {
        switch request.action {
        case .list:
            return .success(devicesStore.v1Devices())
        case .revoke:
            guard let id = request.device, AuthorizedKeys.isDeviceId(id) else {
                return .failure(V1Failure(.badRequest, "not a device id"))
            }
            do {
                guard try devicesStore.revoke(id) else { return .failure(V1Failure(.notFound, "no device \(id)")) }
                return .success(devicesStore.v1Devices())
            } catch {
                return .failure(V1Failure(.unavailable, "\(error)"))
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// When the running binary and a file were last written: a process older than
/// either runs yesterday's code or settings (`hello`, `doctor`).
public enum LampDBinary {
    public static let modifiedAt: Date? = {
        #if os(Linux)
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
        #else
        let path = CommandLine.arguments[0]
        #endif
        return modified(path)
    }()

    public static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
