#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LampBoardCore

/// This Mac's notifications to the phone (W5, §2.6, §2.8–2.9): the devices
/// that registered with it, its envelope key, what was announced, the relay.
///
/// The rule of what to send is the Core's (`PushPlanner`), the one `lampd`
/// follows, applied to the rows this Mac **owns** (`PushOwnership`): its own,
/// and those of the machines without a healthy `lampd`. A node whose `lampd`
/// answers owns its rows and rings for them itself; the Mac then never sends
/// them, so a row rings once (gate «Nessuna doppia notifica»).
///
/// Presence (Q8): while the person is at the Mac (`MacPresence.here`) every
/// device counts as in hand — the panel shows the rows, its banners ring — so
/// nothing rings on the phone; a row still waiting when the person leaves rings
/// then, as a phone put away does. Before the Mac sleeps it says so once
/// (`sleeping`), and its Live Activity goes grey.
///
/// Sending happens on a queue of its own: a slow relay never holds the main
/// thread, which feeds `after` on every change of the column.
public final class MacPushes: @unchecked Sendable {

    public let identity: V1SourceIdentity
    public let directory: String
    public let relay: RelayClient?
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lampboard.mac.push")
    private let key: Curve25519.KeyAgreement.PrivateKey?
    private var state: Saved
    private var devices: [String: Registered]
    private var used: [String: (at: Date, session: String?)] = [:]
    private var health: V1RelayHealth?
    private var lastHealthCheck: Date?
    private var inFlight = 0
    /// Where the person is, as the Mac knows it (Q8).
    public var presence: MacPresence {
        get { locked { currentPresence } }
        set { locked { currentPresence = newValue } }
    }
    private var currentPresence: MacPresence = .here
    /// Every push handed to the relay and what came of it, newest last: what
    /// the checks read. Never a token, a capability or an envelope.
    public private(set) var sent: [Sent] = []

    public struct Sent: Equatable, Sendable {
        public let device: String
        public let kind: PushKind
        public let event: PushEvent?
        public let session: String?
        public let outcome: RelayOutcome
        public let at: Date
        /// The Live Activity's stale date, when it was one.
        public let staleDate: Date?
    }

    public struct Registered: Codable, Equatable, Sendable {
        public var registration: V1PushRegistration
        public let at: Date
    }

    struct Saved: Codable, Equatable {
        var journal: String
        var seq: Int
        var memory: PushMemory
        var lastBackground: [String: Date] = [:]
        var lastLiveActivity: [String: Date] = [:]
        var liveCounts: [String: PushCounts] = [:]
        var backgroundCounts: [String: PushCounts] = [:]
    }

    public static let backgroundEvery: TimeInterval = 150
    public static let liveActivityEvery: TimeInterval = 10 * 60
    public static let liveActivityQuiet: TimeInterval = 60
    public static let healthEvery: TimeInterval = 10 * 60

    public var keyFile: String { directory + "/push-key" }
    public var devicesFile: String { directory + "/push-devices.json" }
    public var stateFile: String { directory + "/push-state.json" }

    /// - Parameter directory: the folder of the paired devices (0700); the
    ///   files written here are 0600.
    public init(identity: V1SourceIdentity, directory: String, relay: RelayClient?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.identity = identity
        self.directory = directory
        self.relay = relay
        self.log = log
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        key = Self.loadKey(directory + "/push-key")
        state = (FileManager.default.contents(atPath: directory + "/push-state.json"))
            .flatMap { try? V1Codec.decoder().decode(Saved.self, from: $0) }
            ?? Saved(journal: "mac-push-" + String(UInt64.random(in: 0...UInt64.max), radix: 36), seq: 0, memory: PushMemory())
        devices = Self.loadDevices(directory + "/push-devices.json")
    }

    // MARK: - Registration

    public func register(_ registration: V1PushRegistration, device: String, at now: Date) -> Result<V1PushAccepted, V1Failure> {
        guard let key else { return .failure(V1Failure(.unavailable, "this Mac has no envelope key")) }
        if let problem = registration.problem { return .failure(V1Failure(.badRequest, problem)) }
        let saved: Bool = locked {
            devices[device] = Registered(registration: registration, at: now)
            return saveDevices()
        }
        guard saved else { return .failure(V1Failure(.unavailable, "the registration could not be kept")) }
        log("push: \(device) registered (\(registration.environment.rawValue)\(registration.liveActivityToken == nil ? "" : ", with a Live Activity"))")
        return .success(V1PushAccepted(envelopeKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                       source: identity.name, device: device))
    }

    /// A device forgotten on the Mac: nothing is sent to it again.
    public func forget(device: String) {
        locked {
            guard devices.removeValue(forKey: device) != nil else { return }
            _ = saveDevices()
        }
    }

    public func used(by device: String, session: String?, at now: Date) {
        locked { used[device] = (now, session) }
    }

    public var relayHealth: V1RelayHealth? { locked { health } }
    public var registeredDevices: [String] { locked { devices.keys.sorted() } }

    // MARK: - After each change of the column

    /// What the column's rows send now. Only the rows this Mac owns count, for
    /// the alerts and for the counts alike: a node's `lampd` counts its own.
    public func after(rows all: [V1Row], at now: Date) {
        guard let relay, let key else { return }
        let rows = PushOwnership.rows(all, ownedBy: identity.name)
        var work: [Work] = []
        locked {
            let atTheMac = currentPresence == .here
            let pushDevices = devices.map { id, registered in
                // At the Mac, every device is as good as in hand: the panel shows
                // the column and rings itself (Q8).
                PushDevice(id: id, preferences: registered.registration.preferences ?? .standard,
                           usedAt: atTheMac ? now : used[id]?.at, focusedSession: atTheMac ? nil : used[id]?.session)
            }
            let (plan, memory) = PushPlanner.plan(rows: rows, devices: pushDevices, memory: state.memory, at: now)
            state.memory = memory
            let counts = memory.lastCounts ?? .zero
            if let until = health?.holdUntil, until > now {
                if !plan.alerts.isEmpty { log("push: \(plan.alerts.count) held back, the relay asked to wait until \(until)") }
                saveState()
                return
            }
            for alert in plan.alerts {
                guard let registered = devices[alert.device] else { continue }
                let content = next(PushContent(source: identity.name, journal: state.journal, seq: 0, at: now, title: alert.title,
                                               body: alert.body, session: alert.session, event: alert.event, counts: counts,
                                               quiet: alert.quiet ? true : nil))
                if let request = seal(content, kind: .alert, urgent: alert.urgent, device: alert.device, registered.registration,
                                      capability: registered.registration.capability, token: registered.registration.token,
                                      key: key, now: now) {
                    work.append(Work(device: alert.device, request: request, kind: .alert, event: alert.event, session: alert.session))
                }
            }
            for (id, registered) in devices {
                work += countsWork(id: id, registration: registered.registration, counts: counts, key: key, now: now, force: false, stale: nil)
            }
            saveState()
        }
        for item in work { send(item, at: now, relay: relay) }
        let due = locked { () -> Bool in
            if !work.isEmpty { lastHealthCheck = now; return false }
            if let until = health?.holdUntil, until > now { return false }
            return lastHealthCheck.map { now.timeIntervalSince($0) >= Self.healthEvery } ?? true
        }
        if due { checkHealth(at: now) }
    }

    /// The Mac is going to sleep (§2.6): one alert to each device when
    /// something waits for the person, and the Live Activity pushed grey (its
    /// stale date now). Returns once the relay answered, or after `timeout`:
    /// the sleep waits for nobody longer than that.
    @discardableResult
    public func sleeping(rows all: [V1Row], at now: Date, timeout: TimeInterval = 5) -> Bool {
        guard let relay, let key else { return false }
        let rows = PushOwnership.rows(all, ownedBy: identity.name)
        var work: [Work] = []
        locked {
            currentPresence = .asleep
            let counts = PushCounts(statuses: rows.filter { !$0.extras.hidden }.map(\.session.status))
            let note = MacSleepNote.text(waiting: counts.waiting, mac: identity.name)
            for (id, registered) in devices {
                let registration = registered.registration
                if let note {
                    let content = next(PushContent(source: identity.name, journal: state.journal, seq: 0, at: now, title: note.title,
                                                   body: note.body, session: nil, event: .summary, counts: counts))
                    if let request = seal(content, kind: .alert, urgent: false, device: id, registration,
                                          capability: registration.capability, token: registration.token, key: key, now: now) {
                        work.append(Work(device: id, request: request, kind: .alert, event: .summary, session: nil))
                    }
                }
                work += countsWork(id: id, registration: registration, counts: counts, key: key, now: now, force: true, stale: now)
            }
            saveState()
        }
        for item in work { send(item, at: now, relay: relay) }
        return drain(timeout: timeout)
    }

    /// Under the lock: the counts for one device, as background and as its
    /// Live Activity, when they are due.
    private func countsWork(id: String, registration: V1PushRegistration, counts: PushCounts,
                            key: Curve25519.KeyAgreement.PrivateKey, now: Date, force: Bool, stale: Date?) -> [Work] {
        var out: [Work] = []
        let lastBackground = state.lastBackground[id] ?? .distantPast
        if !force, state.backgroundCounts[id] != counts, now.timeIntervalSince(lastBackground) >= Self.backgroundEvery {
            let content = next(PushContent(source: identity.name, journal: state.journal, seq: 0, at: now, title: "counts",
                                           body: "", session: nil, event: .counts, counts: counts))
            if let request = seal(content, kind: .background, urgent: false, device: id, registration,
                                  capability: registration.capability, token: registration.token, key: key, now: now) {
                out.append(Work(device: id, request: request, kind: .background, event: .counts, session: nil))
                state.lastBackground[id] = now
                state.backgroundCounts[id] = counts
            }
        }
        if let live = registration.liveActivityToken, let liveCap = registration.liveActivityCapability {
            let since = now.timeIntervalSince(state.lastLiveActivity[id] ?? .distantPast)
            let before = state.liveCounts[id]
            let urgent = before.map { $0.waiting != counts.waiting || $0.failed != counts.failed } ?? true
            let moved = before != counts
            if force || (moved && (urgent || since >= Self.liveActivityQuiet)) || since >= Self.liveActivityEvery {
                let content = next(PushContent(source: identity.name, journal: state.journal, seq: 0, at: now, title: "counts",
                                               body: "", session: nil, event: .counts, counts: counts))
                if let request = seal(content, kind: .liveactivity, urgent: false, device: id, registration,
                                      capability: liveCap, token: live, key: key, now: now, staleDate: stale) {
                    out.append(Work(device: id, request: request, kind: .liveactivity, event: .counts, session: nil, staleDate: stale))
                    state.lastLiveActivity[id] = now
                    state.liveCounts[id] = counts
                }
            }
        }
        return out
    }

    public func checkHealth(at now: Date) {
        guard let relay else { return }
        locked { lastHealthCheck = now }
        queue.async { [self] in
            let outcome = Self.wait { await relay.health() }
            locked { if inFlight == 0 || health == nil { health = outcome.health(at: now) } }
        }
    }

    /// Waits for the queue to empty.
    @discardableResult
    public func drain(timeout: TimeInterval = 30) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - Sealing and sending

    private struct Work {
        let device: String
        let request: RelayPushRequest
        let kind: PushKind
        let event: PushEvent?
        let session: String?
        var staleDate: Date? = nil
    }

    private func next(_ content: PushContent) -> PushContent {
        state.seq += 1
        return PushContent(source: content.source, journal: content.journal, seq: state.seq, at: content.at, title: content.title,
                           body: content.body, session: content.session, event: content.event, counts: content.counts, quiet: content.quiet)
    }

    private func seal(_ content: PushContent, kind: PushKind, urgent: Bool, device: String, _ registration: V1PushRegistration,
                      capability: String, token: String, key: Curve25519.KeyAgreement.PrivateKey, now: Date,
                      staleDate: Date? = nil) -> RelayPushRequest? {
        guard let theirs = Data(base64Encoded: registration.envelopeKey).flatMap({ try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }),
              let pair = try? PushEnvelope.key(mine: key, theirs: theirs, source: identity.name, device: device),
              let sealed = try? PushEnvelope.seal(content, with: pair)
        else {
            log("push: \(device): the envelope could not be sealed")
            return nil
        }
        do {
            return try RelayPushRequest.make(capability: RelayCapability(cap: capability, token: token, environment: registration.environment),
                                             kind: kind, urgent: urgent, sealed: sealed, content: content,
                                             staleDate: kind == .liveactivity ? staleDate : nil, now: now)
        } catch {
            log("push: \(device): refused to send (\(error))")
            return nil
        }
    }

    private func send(_ work: Work, at now: Date, relay: RelayClient) {
        locked { inFlight += 1 }
        queue.async { [self] in
            let outcome = Self.wait { await relay.push(work.request) }
            locked {
                inFlight -= 1
                health = outcome.health(at: now)
                sent.append(Sent(device: work.device, kind: work.kind, event: work.event, session: work.session,
                                 outcome: outcome, at: now, staleDate: work.staleDate))
                if sent.count > 500 { sent.removeFirst(sent.count - 500) }
            }
            log("push: \(work.kind.rawValue)\(work.event.map { " " + $0.rawValue } ?? "") → \(work.device): \(outcome.word)")
            if case .gone = outcome { dropGone(device: work.device, kind: work.kind, token: work.request.token) }
        }
    }

    private func dropGone(device: String, kind: PushKind, token: String) {
        locked {
            guard var registered = devices[device] else { return }
            let r = registered.registration
            if kind == .liveactivity {
                guard r.liveActivityToken == token else { return }
                registered.registration = V1PushRegistration(capability: r.capability, token: r.token, environment: r.environment,
                                                             envelopeKey: r.envelopeKey, preferences: r.preferences)
                devices[device] = registered
            } else {
                guard r.token == token else { return }
                devices[device] = nil
            }
            _ = saveDevices()
        }
        log("push: \(device): its token is gone, dropped")
    }

    static func wait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    // MARK: - Files (0600)

    private func saveState() {
        guard let data = try? V1Codec.encoder().encode(state) else { return }
        _ = Self.write(data, to: stateFile)
    }

    private func saveDevices() -> Bool {
        guard let data = try? V1Codec.encoder().encode(devices) else { return false }
        return Self.write(data, to: devicesFile)
    }

    static func write(_ data: Data, to path: String) -> Bool {
        let temporary = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temporary, path) == 0 else { unlink(temporary); return false }
        return true
    }

    static func loadDevices(_ path: String) -> [String: Registered] {
        guard let data = FileManager.default.contents(atPath: path),
              let all = try? V1Codec.decoder().decode([String: Registered].self, from: data) else { return [:] }
        return all.filter { $0.value.registration.problem == nil }
    }

    static func loadKey(_ path: String) -> Curve25519.KeyAgreement.PrivateKey? {
        if let text = FileManager.default.contents(atPath: path).flatMap({ String(data: $0, encoding: .utf8) }),
           let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        guard write(Data((key.rawRepresentation.base64EncodedString() + "\n").utf8), to: path) else { return nil }
        return key
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
