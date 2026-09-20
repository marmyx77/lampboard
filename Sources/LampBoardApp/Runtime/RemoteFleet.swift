import LampBoardCore
import Foundation

/// One machine's standing, as the Settings window shows it.
struct RemoteHostStatus: Equatable {
    enum Hooks: Equatable {
        case unknown, checking, installed, absent
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "hooks: not checked yet"
            case .checking: return "hooks: checking…"
            case .installed: return "hooks: installed"
            case .absent: return "hooks: not installed"
            case .failed(let reason): return "hooks: \(reason)"
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

    private let preferences: Preferences
    private let localPort: UInt16
    private var tunnels: [String: RemoteTunnel] = [:]
    private var preferenceWatcher: NSObjectProtocol?

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
    }

    func stop() {
        if let preferenceWatcher { NotificationCenter.default.removeObserver(preferenceWatcher) }
        preferenceWatcher = nil
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
                switch RemoteHookInstaller.inspect(host) {
                case .success(let inspection):
                    hooks = inspection.hooksInstalled ? .installed : .absent
                    var notes = ["python \(inspection.pythonVersion)"]
                    if !inspection.hasCurl { notes.append("curl missing: the hook script needs it") }
                    if let problem = inspection.directoryProblem { notes.append("~/.lampboard there \(problem)") }
                    if let error = inspection.error { notes.append("settings.json unreadable: \(error)") }
                    // The one question only the node can answer: where is the port
                    // the hooks post to bound, and does it reach this Mac right now?
                    switch RemoteHookInstaller.tunnelStatus(on: host, port: inspection.port) {
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
                            notes.append("hooks there carry no token and could not be rewritten: \(error.short)")
                        }
                    }
                    outcome = .success("\(host): " + notes.joined(separator: "; "))
                case .failure(let error):
                    hooks = .failed(error.short)
                    outcome = .failure(error)
                }
            case .install:
                outcome = RemoteHookInstaller.install(on: host)
                if case .success = outcome { hooks = .installed }
            case .uninstall:
                outcome = RemoteHookInstaller.uninstall(on: host)
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
        let tunnel = RemoteTunnel(host: host, localPort: localPort) { [weak self] state in
            self?.modify(host) { $0.tunnel = state }
            // A node asleep at launch answered the check with a failure, and its
            // hooks were never looked at. The tunnel coming up is the moment it
            // can be asked again — and repaired, if it needs to be.
            if case .up = state, let hooks = self?.status[host]?.hooks, case .failed = hooks {
                self?.run(.check, on: host)
            }
        }
        tunnels[host] = tunnel
        tunnel.start()
    }

    private func modify(_ host: String, _ change: (inout RemoteHostStatus) -> Void) {
        var current = status[host] ?? RemoteHostStatus()
        change(&current)
        status[host] = current
    }
}
