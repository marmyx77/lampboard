#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LampBoardCore

/// This machine's notifications (W4, §2.8–2.9): the devices that registered,
/// the envelope key, what was already announced, and the relay.
///
/// The rule of what to send is the Core's (`PushPlanner`), the same the Mac
/// will use: this keeps its memory on disk, seals what it decides, and hands it
/// to the relay on a queue of its own, so a slow relay never holds the main
/// loop (the watchdog's beat, ADR-65 point 6).
///
/// Only the service sends. A forced command reading the files (`mode: files`)
/// still takes a registration — written to the same file, which the service
/// reads at its next look — and sends nothing: two senders would ring twice.
public final class NodePushes: @unchecked Sendable {

    public let identity: V1SourceIdentity
    public let paths: LampDPaths
    /// `nil`: this process does not send (a forced command, or notifications
    /// turned off in the configuration).
    public let relay: RelayClient?
    private let log: (String) -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lampd.push")
    private let key: Curve25519.KeyAgreement.PrivateKey?
    private var state: Saved
    private var devices: [String: Registered] = [:]
    private var devicesStamp: Date?
    private var used: [String: (at: Date, session: String?)] = [:]
    private var ledgers: [String: RowsAwayLedger] = [:]
    private var health: V1RelayHealth?
    private var lastHealthCheck: Date?
    private var inFlight = 0
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
    }

    /// One device's registration, as written by whichever process took it.
    public struct Registered: Codable, Equatable, Sendable {
        public var registration: V1PushRegistration
        public let at: Date
    }

    /// What the service keeps between starts.
    struct Saved: Codable, Equatable {
        var journal: String
        var seq: Int
        var memory: PushMemory
        var lastBackground: [String: Date] = [:]
        var lastLiveActivity: [String: Date] = [:]
        var liveCounts: [String: PushCounts] = [:]
        var backgroundCounts: [String: PushCounts] = [:]
    }

    /// The fewest seconds between two background pushes to one device: the
    /// relay allows 30 an hour (`relay/lib/quota.js`).
    public static let backgroundEvery: TimeInterval = 150
    /// A Live Activity is refreshed this often even when nothing changed, so
    /// its stale date only ever passes when this machine is silent.
    public static let liveActivityEvery: TimeInterval = 10 * 60
    /// The fewest seconds between two Live Activity updates when only work
    /// came or went (the relay allows 120 an hour).
    public static let liveActivityQuiet: TimeInterval = 60
    /// How often the relay's `/health` is asked when nothing else was sent.
    public static let healthEvery: TimeInterval = 10 * 60

    public init(identity: V1SourceIdentity, paths: LampDPaths, relay: RelayClient?, log: @escaping (String) -> Void = { _ in }) {
        self.identity = identity
        self.paths = paths
        self.relay = relay
        self.log = log
        key = try? Self.loadKey(paths)
        state = Self.loadState(paths) ?? Saved(journal: "push-" + String(UInt64.random(in: 0...UInt64.max), radix: 36), seq: 0, memory: PushMemory())
        devices = Self.loadDevices(paths)
    }

    // MARK: - Registration

    /// A device's registration, kept for the service: this machine's half of
    /// the envelope key in return.
    public func register(_ registration: V1PushRegistration, device: String, at now: Date) -> Result<V1PushAccepted, V1Failure> {
        guard let key else { return .failure(V1Failure(.unavailable, "this machine has no envelope key: \(paths.pushKeyFile)")) }
        do {
            try LampDPaths.makeDirectory(paths.stateDirectory)
            try FileLock.with(paths.pushDevicesFile + ".lock") {
                var all = Self.loadDevices(paths)
                all[device] = Registered(registration: registration, at: now)
                try AtomicFile.write(try V1Codec.encoder().encode(all), to: paths.pushDevicesFile)
            }
        } catch {
            return .failure(V1Failure(.unavailable, "the registration could not be kept: \(error)"))
        }
        locked { devices = Self.loadDevices(paths) }
        log("push: \(device) registered (\(registration.environment.rawValue)\(registration.liveActivityToken == nil ? "" : ", with a Live Activity"))")
        return .success(V1PushAccepted(envelopeKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                       source: identity.name, device: device))
    }

    /// A device's app said it is in use, in `session` or in the column.
    public func used(by device: String, session: String?, at now: Date) {
        locked { used[device] = (now, session) }
    }

    /// «While you were away» for `device`, once: the ledger starts again.
    public func away(for device: String, rows: [V1Row], at now: Date) -> String? {
        locked {
            let line = ledgers[device]?.summary(now: now, rows: rows)
            ledgers[device] = RowsAwayLedger(since: now, rows: rows)
            return line
        }
    }

    public var relayHealth: V1RelayHealth? { locked { health } }
    public var registeredDevices: [String] { locked { devices.keys.sorted() } }

    // MARK: - After each look

    /// The pseudo-device that stands for the person at the Mac (Q8): present
    /// while the Mac says so, so the planner treats the column as seen — nobody's
    /// phone rings, an amber stays unannounced and rings when the Mac goes away
    /// — and never a device anything is sent to.
    public static let macAtTheDesk = "mac-at-the-desk"

    /// What the rows of one look send. Called by the service only. `macHere`:
    /// the person is at the Mac (`lampd mac-link`, Q8), whose own banners ring
    /// for these rows; the phone does not ring as well (§6.2 «Nessuna doppia
    /// notifica»).
    public func after(rows: [V1Row], at now: Date, macHere: Bool = false) {
        guard let relay, let key else { return }
        var work: [(device: String, request: RelayPushRequest, kind: PushKind, event: PushEvent?, session: String?)] = []
        locked {
            reloadDevicesIfChanged()
            var pushDevices = devices.map { id, registered in
                PushDevice(id: id, preferences: registered.registration.preferences ?? .standard,
                           usedAt: used[id]?.at, focusedSession: used[id]?.session)
            }
            if macHere { pushDevices.append(PushDevice(id: Self.macAtTheDesk, usedAt: now)) }
            for device in pushDevices where !device.isPresent(at: now) && device.id != Self.macAtTheDesk {
                let id = device.id
                if ledgers[id] == nil { ledgers[id] = RowsAwayLedger(since: now, rows: rows) } else { ledgers[id]?.observe(rows) }
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
                if let request = seal(content, kind: .alert, urgent: alert.urgent, to: alert.device, registered.registration,
                                      capability: registered.registration.capability, token: registered.registration.token, key: key, now: now) {
                    work.append((alert.device, request, .alert, alert.event, alert.session))
                }
            }
            for (id, registered) in devices {
                let registration = registered.registration
                let lastBackground = state.lastBackground[id] ?? .distantPast
                if state.backgroundCounts[id] != counts, now.timeIntervalSince(lastBackground) >= Self.backgroundEvery {
                    let content = next(PushContent(source: identity.name, journal: state.journal, seq: 0, at: now, title: "counts",
                                                   body: "", session: nil, event: .counts, counts: counts))
                    if let request = seal(content, kind: .background, urgent: false, to: id, registration,
                                          capability: registration.capability, token: registration.token, key: key, now: now) {
                        work.append((id, request, .background, .counts, nil))
                        state.lastBackground[id] = now
                        state.backgroundCounts[id] = counts
                    }
                }
                if let live = registration.liveActivityToken, let liveCap = registration.liveActivityCapability {
                    let last = state.lastLiveActivity[id] ?? .distantPast
                    let since = now.timeIntervalSince(last)
                    // A row starting or stopping to want the person shows at
                    // once; work coming and going waits a minute, or a busy
                    // machine would spend the relay's quota in a quarter of an
                    // hour (seen on the fake node: one every look).
                    let before = state.liveCounts[id]
                    let urgent = before.map { $0.waiting != counts.waiting || $0.failed != counts.failed } ?? true
                    let moved = before != counts
                    if (moved && (urgent || since >= Self.liveActivityQuiet)) || since >= Self.liveActivityEvery {
                        let content = next(PushContent(source: identity.name, journal: state.journal, seq: 0, at: now, title: "counts",
                                                       body: "", session: nil, event: .counts, counts: counts))
                        if let request = seal(content, kind: .liveactivity, urgent: false, to: id, registration,
                                              capability: liveCap, token: live, key: key, now: now) {
                            work.append((id, request, .liveactivity, .counts, nil))
                            state.lastLiveActivity[id] = now
                            state.liveCounts[id] = counts
                        }
                    }
                }
            }
            saveState()
        }
        for item in work { send(item.request, device: item.device, kind: item.kind, event: item.event, session: item.session, at: now, relay: relay) }
        // The relay's word is fresh when a push just had it, and a hold it asked
        // for is not overwritten by a health check.
        let due = locked { () -> Bool in
            if !work.isEmpty { lastHealthCheck = now; return false }
            if let until = health?.holdUntil, until > now { return false }
            return lastHealthCheck.map { now.timeIntervalSince($0) >= Self.healthEvery } ?? true
        }
        if due { checkHealth(at: now) }
    }

    /// Asks the relay how it is, on the push queue; `hello` says it.
    public func checkHealth(at now: Date) {
        guard let relay else { return }
        locked { lastHealthCheck = now }
        queue.async { [self] in
            let outcome = Self.wait { await relay.health() }
            locked {
                // A push's answer is newer news than a health check's.
                if inFlight == 0 || health == nil { health = outcome.health(at: now) }
            }
        }
    }

    /// Waits for the queue to empty: the checks read `sent` after it.
    public func drain(timeout: TimeInterval = 30) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - Sealing and sending

    private func next(_ content: PushContent) -> PushContent {
        state.seq += 1
        return PushContent(source: content.source, journal: content.journal, seq: state.seq, at: content.at, title: content.title,
                           body: content.body, session: content.session, event: content.event, counts: content.counts, quiet: content.quiet)
    }

    private func seal(_ content: PushContent, kind: PushKind, urgent: Bool, to device: String, _ registration: V1PushRegistration,
                      capability: String, token: String, key: Curve25519.KeyAgreement.PrivateKey, now: Date) -> RelayPushRequest? {
        guard let theirs = Data(base64Encoded: registration.envelopeKey).flatMap({ try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }),
              let pair = try? PushEnvelope.key(mine: key, theirs: theirs, source: identity.name, device: device),
              let sealed = try? PushEnvelope.seal(content, with: pair)
        else {
            log("push: \(device): the envelope could not be sealed")
            return nil
        }
        do {
            return try RelayPushRequest.make(capability: RelayCapability(cap: capability, token: token, environment: registration.environment),
                                             kind: kind, urgent: urgent, sealed: sealed, content: content, now: now)
        } catch {
            // The gate «Il relay non legge»: a request whose bytes say what the
            // envelope hides is never sent.
            log("push: \(device): refused to send (\(error))")
            return nil
        }
    }

    private func send(_ request: RelayPushRequest, device: String, kind: PushKind, event: PushEvent?, session: String?,
                      at now: Date, relay: RelayClient) {
        locked { inFlight += 1 }
        queue.async { [self] in
            let started = Date()
            let outcome = Self.wait { await relay.push(request) }
            locked {
                inFlight -= 1
                // At the look's time: what `hold` is compared with.
                health = outcome.health(at: now)
                sent.append(Sent(device: device, kind: kind, event: event, session: session, outcome: outcome, at: now))
                if sent.count > 500 { sent.removeFirst(sent.count - 500) }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("push: \(kind.rawValue)\(event.map { " " + $0.rawValue } ?? "") → \(device): \(outcome.word) in \(ms) ms")
            if case .gone = outcome { forget(device: device, kind: kind, token: request.token) }
        }
    }

    /// APNs said the token is gone: the device's registration (or only its
    /// Live Activity) is dropped, so nothing is sent to it again.
    private func forget(device: String, kind: PushKind, token: String) {
        do {
            try FileLock.with(paths.pushDevicesFile + ".lock") {
                var all = Self.loadDevices(paths)
                guard var registered = all[device] else { return }
                if kind == .liveactivity {
                    guard registered.registration.liveActivityToken == token else { return }
                    let r = registered.registration
                    registered.registration = V1PushRegistration(capability: r.capability, token: r.token, environment: r.environment,
                                                                 envelopeKey: r.envelopeKey, preferences: r.preferences)
                    all[device] = registered
                } else {
                    guard registered.registration.token == token else { return }
                    all[device] = nil
                }
                try AtomicFile.write(try V1Codec.encoder().encode(all), to: paths.pushDevicesFile)
            }
            locked { devices = Self.loadDevices(paths) }
            log("push: \(device): \(kind == .liveactivity ? "its Live Activity token" : "its token") is gone, dropped")
        } catch {
            log("push: \(device): the gone token could not be dropped: \(error)")
        }
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

    // MARK: - Files

    private func reloadDevicesIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: paths.pushDevicesFile))?[.modificationDate] as? Date
        if stamp != devicesStamp {
            devicesStamp = stamp
            devices = Self.loadDevices(paths)
        }
    }

    private func saveState() {
        guard let data = try? V1Codec.encoder().encode(state) else { return }
        try? AtomicFile.write(data, to: paths.pushStateFile)
    }

    static func loadState(_ paths: LampDPaths) -> Saved? {
        FileManager.default.contents(atPath: paths.pushStateFile).flatMap { try? V1Codec.decoder().decode(Saved.self, from: $0) }
    }

    static func loadDevices(_ paths: LampDPaths) -> [String: Registered] {
        guard let data = FileManager.default.contents(atPath: paths.pushDevicesFile),
              let all = try? V1Codec.decoder().decode([String: Registered].self, from: data)
        else { return [:] }
        // A file edited by hand keeps only what would have been taken.
        return all.filter { AuthorizedKeys.isDeviceId($0.key) && $0.value.registration.problem == nil }
    }

    /// The envelope key, made once and kept `0600`; the service and a forced
    /// command make it under the same lock, so there is only ever one.
    static func loadKey(_ paths: LampDPaths) throws -> Curve25519.KeyAgreement.PrivateKey {
        try LampDPaths.makeDirectory(paths.stateDirectory)
        return try FileLock.with(paths.pushKeyFile + ".lock") {
            if let text = FileManager.default.contents(atPath: paths.pushKeyFile).flatMap({ String(data: $0, encoding: .utf8) }),
               let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                return key
            }
            let key = Curve25519.KeyAgreement.PrivateKey()
            try AtomicFile.write(Data((key.rawRepresentation.base64EncodedString() + "\n").utf8), to: paths.pushKeyFile)
            return key
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension LampDPaths {
    /// This machine's half of every envelope key (X25519, base64, `0600`).
    public var pushKeyFile: String { stateDirectory + "/push-key" }
    /// The devices' push registrations (`0600`: tokens and capabilities).
    public var pushDevicesFile: String { stateDirectory + "/push-devices.json" }
    /// What was announced, the envelopes' count, when each device last got counts.
    public var pushStateFile: String { stateDirectory + "/push-state.json" }
}
