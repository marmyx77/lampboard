import AppKit
import Combine
import Foundation
import LampBoardCore
import LampBoardMacSource

/// This Mac as a source for iPhone and iPad (W5, §2.4, §2.6): the ssh server
/// inside the app, the paired devices, the pairing window, Bonjour, and the
/// panel's column fed to `v1` as it changes.
///
/// The server listens only while there is something to serve: a paired device,
/// or a pairing window open. Without either, no port is open at all.
@MainActor
final class MobileServer: ObservableObject {

    @Published private(set) var devices: [MacDevices.Device] = []
    @Published private(set) var invitation: MacPairingInvitation?
    @Published private(set) var pairingDeadline: Date?
    @Published private(set) var problem: String?
    @Published private(set) var listeningPort: Int?

    let settings = MobileSettings()
    let attaches = MacAttachLedger()
    let hubShares = HubShares()
    private let store: StateStore
    private let snapshots: SnapshotBox
    private let preferences: Preferences
    private let tmuxPlaces: () -> [String: TmuxPlace]
    private let deviceStore = MacDevices(directory: MobileSettings.directory)
    private let pairing = MacPairingWindow()
    private let source: MacV1Source
    private var server: MacSSHServer?
    private var bonjour: NetService?
    private var watch: AnyCancellable?
    private var pairingClock: Timer?

    /// The name the person gave this Mac, never its host name (S-P).
    let macName: String = Host.current().localizedName ?? "Mac"

    init(store: StateStore, snapshots: SnapshotBox, preferences: Preferences, tmuxPlaces: @escaping () -> [String: TmuxPlace]) {
        self.store = store
        self.snapshots = snapshots
        self.preferences = preferences
        self.tmuxPlaces = tmuxPlaces
        let deviceStore = self.deviceStore
        let identity = V1SourceIdentity(kind: .mac, name: Host.current().localizedName ?? "Mac")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let relay = PerformRelay()
        source = MacV1Source(
            identity: identity, version: version, startedAt: Date(),
            actions: MacSourceActions(
                perform: { command, _ in
                    // The person's choices are the panel's: carried out on the main
                    // actor, never waited for here (the server's threads must not
                    // wait on the main thread, which may be waiting on them).
                    DispatchQueue.main.async { MainActor.assumeIsolated { relay.target?.perform(command) } }
                    return nil
                },
                devices: { request in Self.devices(request, in: deviceStore) }
            )
        )
        relay.target = self
    }

    // MARK: - Starting and stopping

    func start() {
        devices = deviceStore.all
        // A fake home may open a pairing window at launch with a code it names,
        // for a phone that pairs from another machine (the gate's T1 on Linux).
        if AppConfig.isUsingHomeOverride, let code = ProcessInfo.processInfo.environment["LAMPBOARD_MOBILE_PAIR_CODE"],
           MacPairingCode.isWellFormed(code) {
            _ = pairing.open(at: Date(), code: code)
        }
        watch = store.$state
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
        publish()
        listenIfNeeded()
    }

    func stop() {
        pairingClock?.invalidate()
        bonjour?.stop()
        bonjour = nil
        server?.stop()
        server = nil
        listeningPort = nil
    }

    /// Listens when there is a device or a window; stops when there is neither.
    private func listenIfNeeded() {
        let wanted = !deviceStore.isEmpty || pairing.isOpen(at: Date())
        if wanted, server == nil { listen() }
        if !wanted, server != nil { stop() }
    }

    private func listen() {
        do {
            let key = try MacHostKey.loadOrMake(MobileSettings.hostKeyStore)
            let services = MacSSHServer.Services(
                source: source, devices: deviceStore, pairing: pairing, runner: runner(),
                terminalsOn: { [settings] in settings.terminalsOn },
                confirmPairing: { [weak self] request in await self?.confirm(request) ?? false },
                macName: macName,
                log: { line in Diagnostics.log(line) }
            )
            var made: MacSSHServer?
            for port in [settings.port, 0] where made == nil {
                let candidate = MacSSHServer(configuration: MacSSHServer.Configuration(hostKey: key, port: port, hosts: ["0.0.0.0"]),
                                             services: services)
                do {
                    let bound = try candidate.start()
                    settings.port = bound
                    listeningPort = bound
                    made = candidate
                } catch {
                    candidate.stop()
                    if port == 0 { throw error }
                }
            }
            server = made
            problem = nil
            advertise(key: MacHostKey.openSSH(key))
        } catch {
            problem = "The iPhone & iPad server could not start: \(error)"
            Diagnostics.log(problem ?? "")
        }
    }

    /// Bonjour: a hint of where this Mac is, never a sign that it is alive
    /// (E11); the TXT carries the short fingerprint and the protocol.
    private func advertise(key: String) {
        guard let port = listeningPort else { return }
        // A fake home says nothing to the network unless asked: a gate run on a
        // shared LAN must not show up in someone's list of Macs.
        if AppConfig.isUsingHomeOverride, ProcessInfo.processInfo.environment["LAMPBOARD_MOBILE_BONJOUR"] != "1" { return }
        let service = NetService(domain: "local.", type: MacBridge.bonjourType + ".", name: macName, port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "v": Data(String(V1Protocol.version).utf8),
            "fp": Data(MacHostKey.shortFingerprint(openSSH: key).utf8),
        ]))
        service.publish()
        bonjour?.stop()
        bonjour = service
    }

    private func runner() -> MacRunner {
        let home = AppConfig.homeDirectory.path
        let environment = LiveLaunch.environment(base: ProcessInfo.processInfo.environment, home: home,
                                                 claude: LampMasterRunner.executable())
        // Under a fake home only the fake home's own tmux, as everywhere else:
        // a test must never reach the person's sessions.
        let tmux = LocalTmuxPlaces.executable()
            ?? (AppConfig.isUsingHomeOverride ? home + "/.local/bin/tmux" : "/opt/homebrew/bin/tmux")
        // Read where they are kept, from the server's threads: UserDefaults is
        // safe to read from any thread, the panel's objects are not.
        let defaults = DefaultsBox(Preferences.sharedDefaults)
        return MacRunner(
            tmux: [tmux], environment: environment, home: home,
            bypassAllowed: { Preferences(defaults: defaults.value).sessionPermissions == .bypass },
            hub: hubShares,
            palette: { MobilePalette.json(Preferences(defaults: defaults.value).liveAppearance) },
            attaches: attaches
        )
    }

    // MARK: - Pairing

    /// Opens a two-minute window and the QR code that goes with it.
    func openPairing() {
        let (code, closes) = pairing.open(at: Date())
        listenIfNeeded()
        guard let port = listeningPort, let key = try? MacHostKey.loadOrMake(MobileSettings.hostKeyStore) else { return }
        invitation = MacPairingInvitation(name: macName, hostKey: MacHostKey.openSSH(key),
                                          addresses: MobileAddresses.current(), port: port, code: code)
        pairingDeadline = closes
        pairingClock?.invalidate()
        pairingClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPairing() }
        }
    }

    func closePairing() {
        pairing.close()
        invitation = nil
        pairingDeadline = nil
        pairingClock?.invalidate()
        listenIfNeeded()
    }

    private func tickPairing() {
        devices = deviceStore.all
        if !pairing.isOpen(at: Date()) { closePairing() }
    }

    /// The person decides, here, with the device's fingerprints in front of them.
    private func confirm(_ request: MacPairingRequest) async -> Bool {
        if AppConfig.isUsingHomeOverride {
            return ProcessInfo.processInfo.environment["LAMPBOARD_MOBILE_CONFIRM"] == "yes"
        }
        return await withCheckedContinuation { done in
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Pair \u{201C}\(request.name)\u{201D} with this Mac?"
                alert.informativeText = "It will see this Mac's sessions. Check that these match what the device shows:\n\n"
                    + "Read key  \(MacHostKey.fingerprint(openSSH: request.readKey))\n"
                    + "Action key  \(MacHostKey.fingerprint(openSSH: request.actionKey))"
                alert.addButton(withTitle: "Pair")
                alert.addButton(withTitle: "Don\u{2019}t Pair")
                let yes = alert.runModal() == .alertFirstButtonReturn
                done.resume(returning: yes)
                Task { @MainActor in
                    self?.devices = self?.deviceStore.all ?? []
                    if yes { self?.closePairing() }
                }
            }
        }
    }

    // MARK: - Devices

    func forget(_ id: String) {
        _ = try? deviceStore.revoke(id)
        server?.disconnect(device: id)
        devices = deviceStore.all
        listenIfNeeded()
    }

    func forgetAll() {
        let ids = deviceStore.all.map(\.id)
        try? deviceStore.forgetAll()
        for id in ids { server?.disconnect(device: id) }
        devices = []
        listenIfNeeded()
    }

    func setTerminals(_ on: Bool) {
        settings.terminalsOn = on
        objectWillChange.send()
    }

    nonisolated static func devices(_ request: V1DevicesRequest, in store: MacDevices) -> Result<[V1Device], V1Failure> {
        switch request.action {
        case .list:
            return .success(store.v1Devices)
        case .revoke:
            guard let id = request.device, (try? store.revoke(id)) == true else {
                return .failure(V1Failure(.notFound, "no device \(request.device ?? "")"))
            }
            return .success(store.v1Devices)
        }
    }

    // MARK: - The column

    /// The column as the read endpoint publishes it, with what the panel knows
    /// of each row besides.
    private func publish() {
        let order = preferences.rowOrder
        let hidden = preferences.hiddenWorkspaces
        let places = tmuxPlaces()
        var facts: [String: MacRows.Facts] = [:]
        for session in store.state.ordered {
            let key = session.workspace.key
            let terminal = session.backgroundJob.map { "job:\($0.id)" } ?? places[session.id].map { "tmux:\($0.session)" }
            facts[session.id] = MacRows.Facts(
                hidden: hidden.contains(key), order: order.firstIndex(of: key), terminal: terminal,
                permissionMode: store.permissionModes[session.id]
            )
        }
        source.update(MacRows.rows(snapshots.current(), mac: source.identity, facts: facts), at: Date())
    }

    /// A low-power action from a device, on a row the column shows.
    private func perform(_ command: V1Command) {
        guard let id = command.session, let session = store.state.sessions[id] else {
            if command.action == .order, let ids = command.ids {
                let keys = ids.compactMap { store.state.sessions[$0]?.workspace.key }
                preferences.rowOrder = keys + preferences.rowOrder.filter { !keys.contains($0) }
            }
            return
        }
        let key = session.workspace.key
        switch command.action {
        case .markSeen: store.markSeen(sessionId: id)
        case .markUnread: store.markUnread(sessionId: id)
        case .dismiss: store.dismiss(sessionId: id)
        case .rename:
            var names = preferences.rowNames
            let name = (command.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            names[key] = name.isEmpty ? nil : name
            preferences.rowNames = names
        case .mute:
            preferences.mutedWorkspaces = (command.on ?? true) ? preferences.mutedWorkspaces.union([key])
                                                                : preferences.mutedWorkspaces.subtracting([key])
        case .hide:
            preferences.hiddenWorkspaces = (command.on ?? true) ? preferences.hiddenWorkspaces.union([key])
                                                                  : preferences.hiddenWorkspaces.subtracting([key])
        case .calmBlink:
            preferences.calmBlinkWorkspaces = preferences.calmBlinkWorkspaces.union([key])
        case .focus, .order:
            break
        }
        publish()
    }
}

/// `UserDefaults` is safe to read from any thread (Apple says so); this says it
/// to the compiler, for the closures the server calls on its own threads.
final class DefaultsBox: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}

/// Hands a device's action to the server once it exists (it is made after
/// the source that needs it).
final class PerformRelay: @unchecked Sendable {
    weak var target: MobileServer?
}

/// The addresses the QR code offers, in order: the LAN's, then the tailnet's
/// (the address range Tailscale gives its machines). Bonjour finds the Mac by
/// itself in the same house.
enum MobileAddresses {
    static func current() -> [String] {
        var lan: [String] = [], tailnet: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            let octets = text.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { tailnet.append(text) } else { lan.append(text) }
        }
        return Array((lan + tailnet).prefix(4))
    }
}

/// The colours of the Mac's terminal, *Like my VS Code* included: what the
/// phone's terminal takes so it looks like the Mac's.
enum MobilePalette {
    static func json(_ appearance: LiveAppearance) -> [UInt8] {
        let theme = appearance.theme
        var object: [String: Any] = ["background": theme.card, "text": theme.text, "fontSize": appearance.fontSize]
        if let cursor = theme.cursor { object["cursor"] = cursor }
        if let selection = theme.selection { object["selection"] = selection }
        if let ansi = theme.ansi { object["ansi"] = ansi }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Array(data) + [0x0A]
    }
}
