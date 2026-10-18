import LampBoardCore
import Foundation

/// One machine's standing, as the Settings window shows it.
struct RemoteHostStatus: Equatable {
    enum Hooks: Equatable {
        case unknown, checking, installed, absent
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "connection: not checked yet"
            case .checking: return "connection: checking…"
            case .installed: return "connected"
            case .absent: return "not connected"
            case .failed(let reason): return "connection: \(reason)"
            }
        }
    }

    var tunnel: RemoteTunnel.State = .stopped
    var hooks: Hooks = .unknown
    /// `true` while something runs over ssh on it; the buttons wait.
    var busy = false
    /// What the last operation said, in one line.
    var message: String?
}

/// Every configured remote machine: its tunnel, its hooks, what it last said.
///
/// The one owner of the tunnels. Hosts come from the preferences and go back to
/// them; adding one starts its tunnel, removing one stops it. Work over ssh
/// blocks, so it runs off the main actor and reports back here — the window never
/// waits on a machine that is asleep.
@MainActor
final class RemoteFleet: ObservableObject {

    enum Operation: Sendable { case check, install, uninstall }

    @Published private(set) var hosts: [String]
    @Published private(set) var status: [String: RemoteHostStatus] = [:]
    /// The hosts whose `lampd` answers on the tunnel's link (W5): each owns its
    /// own rows (§2.9), and the Mac stops notifying them.
    @Published private(set) var lampdHealthy: Set<String> = []
    /// The person's choices about a node's rows, as its `lampd` sent them.
    var onNodePreferences: (String, RowPreferences) -> Void = { _, _ in }
    /// A node's link answered on a new connection: the app sends what only it
    /// knows (the one-time migration of the panel's choices).
    var onLinked: (String) -> Void = { _ in }
    /// Where the person is, and the settings the phone needs on the nodes:
    /// told to every node now and again at each new link (§2.12, Q8).
    private(set) var presence: MacPresence = .here
    private(set) var nodeSettings: MacNodeSettings?

    private let preferences: Preferences
    private let localPort: UInt16
    private var tunnels: [String: RemoteTunnel] = [:]
    private var preferenceWatcher: NSObjectProtocol?
    private var preferencePoll: Timer?
    private var presenceTimer: Timer?

    init(preferences: Preferences, localPort: UInt16) {
        self.preferences = preferences
        self.localPort = localPort
        self.hosts = preferences.remoteHosts
    }

    /// Opens a tunnel to every configured host and asks each about its hooks.
    ///
    /// From then on the list is followed, not just read once: `lampboard remote
    /// add` from a terminal writes the same preference, and the tunnel it asks for
    /// should not wait for a restart.
    func start() {
        for host in hosts {
            startTunnel(host)
            run(.check, on: host)
        }
        preferenceWatcher = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.followPreferences() }
        }
        // That notification is this process's own: a `lampboard remote add` from
        // a terminal is another process, and its write raised nothing here — the
        // tunnel came up only when the panel happened to write a preference of
        // its own (found on the test VM). So the list is also read on the
        // remote poll's clock.
        preferencePoll = Timer.scheduledTimer(withTimeInterval: AppConfig.remotePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followPreferences() }
        }
        // Presence renewed on every link (W5): `lampd` reads a `here` not renewed
        // as the Mac gone.
        presenceTimer = Timer.scheduledTimer(withTimeInterval: MacNodeLink.presenceRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.broadcast(MacToNode(presence: self.presence, at: Date()))
            }
        }
    }

    func stop() {
        if let preferenceWatcher { NotificationCenter.default.removeObserver(preferenceWatcher) }
        preferenceWatcher = nil
        preferencePoll?.invalidate()
        preferencePoll = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        for tunnel in tunnels.values { tunnel.stop() }
        tunnels = [:]
    }

    /// Reconciles the tunnels with the list as it is now stored.
    private func followPreferences() {
        let stored = preferences.remoteHosts
        guard stored != hosts else { return }
        for gone in hosts where !stored.contains(gone) {
            tunnels[gone]?.stop()
            tunnels[gone] = nil
            status[gone] = nil
            lampdHealthy.remove(gone)
        }
        for added in stored where !hosts.contains(added) {
            startTunnel(added)
            run(.check, on: added)
        }
        hosts = stored
    }

    /// Adds a machine. Returns what is wrong with the name, or `nil` when it was added.
    @discardableResult
    func add(_ rawName: String) -> String? {
        let name = rawName.trimmed
        guard RemoteHostList.isUsable(name) else {
            return "“\(name)” is not a name ssh can take: letters, digits, . - _ @ : only, and no leading dash."
        }
        guard !hosts.contains(name) else { return "\(name) is already in the list." }
        hosts.append(name)
        preferences.remoteHosts = hosts
        startTunnel(name)
        run(.check, on: name)
        return nil
    }

    /// Forgets a machine: its tunnel closes, its rows stop being confirmed and go.
    /// The hooks installed there stay; "Remove hooks" is a separate, explicit act.
    func remove(_ host: String) {
        hosts.removeAll { $0 == host }
        preferences.remoteHosts = hosts
        tunnels[host]?.stop()
        tunnels[host] = nil
        status[host] = nil
        lampdHealthy.remove(host)
    }

    /// Runs one operation on a machine, off the main actor, and records the outcome.
    func run(_ operation: Operation, on host: String) {
        guard hosts.contains(host), status[host]?.busy != true else { return }
        modify(host) {
            $0.busy = true
            if operation == .check { $0.hooks = .checking }
        }

        Task.detached(priority: .utility) { [weak self] in
            let outcome: Result<String, RemoteCommandError>
            var hooks: RemoteHostStatus.Hooks?

            switch operation {
            case .check:
                let tunnelPort = await MainActor.run { [weak self] in self?.tunnels[host]?.boundPort }
                switch RemoteHookInstaller.inspect(host) {
                case .success(let inspection):
                    hooks = inspection.hooksInstalled ? .installed : .absent
                    var notes = ["python \(inspection.pythonVersion)"]
                    notes.append(inspection.claudeVersion.map { "Claude Code \($0)" } ?? "Claude Code version not read")
                    if let note = NativeHookSupport.note(for: inspection.claudeVersion) { notes.append(note) }
                    if !inspection.hasCurl { notes.append("curl missing: the connection needs it") }
                    if let problem = inspection.directoryProblem { notes.append("~/.lampboard there \(problem)") }
                    if let error = inspection.error { notes.append("settings.json unreadable: \(error)") }
                    // The one question only the node can answer: where is the port
                    // the hooks post to bound, and does it reach this Mac right now?
                    if inspection.lampd { notes.append("lampd there: hooks left to it") }
                    switch RemoteHookInstaller.tunnelStatus(on: host, port: tunnelPort ?? inspection.port) {
                    case .success(let tunnel): notes.append(tunnel.sentence)
                    case .failure(let error): notes.append("tunnel not checked: \(error.short)")
                    }
                    // Hooks written there by an earlier version carry no token.
                    // The check runs at every launch, so this is where the node
                    // stops depending on somebody remembering a button (D48).
                    if let repair = RemoteHookInstaller.repairToken(
                        on: host, inspection: inspection, token: TokenStore().read()
                    ) {
                        switch repair {
                        case .success(let text): notes.append(text)
                        case .failure(let error):
                            notes.append("the connection there carries no token and could not be rewritten: \(error.short)")
                        }
                    }
                    // A mod of another version than this app's, put there by an
                    // earlier one, is brought up to date the same way.
                    switch RemoteModInstaller.refresh(on: host, inspection: inspection) {
                    case .success(let text)?: notes.append(text)
                    case .failure(let error)?: notes.append("helper there not updated: \(error.short)")
                    case nil: if let version = inspection.modVersion { notes.append("helper \(version)") }
                    }
                    outcome = .success("\(host): " + notes.joined(separator: "; "))
                case .failure(let error):
                    hooks = .failed(error.short)
                    outcome = .failure(error)
                }
            case .install:
                outcome = RemoteHookInstaller.installWithMod(on: host)
                if case .success = outcome { hooks = .installed }
            case .uninstall:
                outcome = RemoteHookInstaller.uninstallWithMod(on: host)
                if case .success = outcome { hooks = .absent }
            }

            let message: String
            switch outcome {
            case .success(let text): message = text
            case .failure(let error): message = error.short
            }
            let newHooks = hooks
            await MainActor.run { [weak self] in
                self?.modify(host) {
                    $0.busy = false
                    $0.message = message
                    if let newHooks { $0.hooks = newHooks }
                }
            }
        }
    }

    // MARK: - Internal

    private func startTunnel(_ host: String) {
        guard tunnels[host] == nil else { return }
        let tunnel = RemoteTunnel(host: host, localPort: localPort, onChange: { [weak self] state in
            self?.modify(host) { $0.tunnel = state }
            // A node asleep at launch answered the check with a failure, and its
            // hooks were never looked at. The tunnel coming up is the moment it
            // can be asked again — and repaired, if it needs to be.
            if case .up = state, let hooks = self?.status[host]?.hooks, case .failed = hooks {
                self?.run(.check, on: host)
            }
        }, onLink: { [weak self] news in
            self?.heard(news, from: host)
        })
        tunnels[host] = tunnel
        tunnel.start()
    }

    // MARK: - The link to each node's lampd (W5)

    private func heard(_ news: RemoteTunnel.LinkNews, from host: String) {
        switch news {
        case .health(let healthy):
            if healthy { lampdHealthy.insert(host) } else { lampdHealthy.remove(host) }
        case .linked:
            let now = Date()
            tunnels[host]?.send(MacToNode(presence: presence, at: now))
            if let nodeSettings { tunnels[host]?.send(MacToNode(settings: nodeSettings, at: now)) }
            onLinked(host)
        case .preferences(let preferences):
            onNodePreferences(host, preferences)
        }
    }

    /// Where the person is (Q8): every node hears it at once.
    func setPresence(_ presence: MacPresence) {
        guard presence != self.presence else { return }
        self.presence = presence
        broadcast(MacToNode(presence: presence, at: Date()))
    }

    /// The Mac's settings the phone reads from the nodes (§2.12).
    func setNodeSettings(_ settings: MacNodeSettings) {
        guard settings != nodeSettings else { return }
        nodeSettings = settings
        broadcast(MacToNode(settings: settings, at: Date()))
    }

    /// One line to one node's `lampd`, when its link is up.
    func send(_ message: MacToNode, to host: String) {
        tunnels[host]?.send(message)
    }

    private func broadcast(_ message: MacToNode) {
        for tunnel in tunnels.values { tunnel.send(message) }
    }

    private func modify(_ host: String, _ change: (inout RemoteHostStatus) -> Void) {
        var current = status[host] ?? RemoteHostStatus()
        change(&current)
        status[host] = current
    }
}
