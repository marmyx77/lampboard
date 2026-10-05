import LampBoardCore
import Foundation

/// The ssh tunnel that lets another machine's hooks reach this one.
///
/// `ssh -N -R 127.0.0.1:<port>:127.0.0.1:<localPort> host`, where `<port>` is
/// derived from the user's uid over there: on the node, that loopback port
/// becomes this app's server, so the hook script installed there posts to it and
/// needs no knowledge of where the Mac is.
///
/// **Three things the first version took on trust, and this one checks.** The
/// bind address in `-R` is a *request* — OpenSSH overrides it to the wildcard
/// under `GatewayPorts yes`, and tells the client only in a debug message — so
/// after every connect the node is asked, from `/proc/net/tcp`, where the port
/// really is; anything but loopback closes the tunnel and says so. A port shared
/// by every account on the machine is nobody's, so the port is the user's own,
/// from the uid. And a port already bound when the tunnel asks for it — a ghost
/// of the last connection, another Mac, a stranger — is seen *before* the ask,
/// not discovered as a failure after it. (A Unix socket in the user's home would
/// have had none of these problems; it was tried, and the machine at hand —
/// Tailscale SSH, whose daemon forwards as root — created it `root:root 0600`.)
///
/// It is kept alive, not merely started: ssh exits when the node sleeps, the VPN
/// drops or the Mac wakes, and each exit schedules a restart with a doubling
/// delay, reset to the minimum after a run that lasted. `ExitOnForwardFailure`
/// makes a refused bind an exit with a reason instead of a tunnel that looks up
/// and carries nothing.
@MainActor
final class RemoteTunnel {

    enum State: Equatable {
        case starting
        /// ssh is running, and the node confirmed the forward is bound to loopback only.
        case up(since: Date)
        /// ssh exited; the reason, and when the next attempt is.
        case down(reason: String, retryIn: TimeInterval)
        /// The node bound the forward to an address other than loopback. The tunnel
        /// was closed and will not be retried until the app restarts: this is the
        /// machine's ssh server ignoring the request, and only its owner can fix it.
        case exposed(on: String)
        case stopped

        var label: String {
            switch self {
            case .starting: return "connecting…"
            case .up: return "connected"
            case .down(let reason, let retry): return "down: \(reason); retrying in \(Int(retry)) s"
            case .exposed(let address): return "closed: the machine bound the forward on \(address), not loopback"
            case .stopped: return "off"
            }
        }
    }

    let host: String
    private let localPort: UInt16
    private let onChange: @MainActor (State) -> Void

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            Diagnostics.log("tunnel \(host): \(state.label)")
            onChange(state)
        }
    }

    private var process: Process?
    private var retryTimer: Timer?
    private var delay: TimeInterval = AppConfig.remoteTunnelRetryMin
    private var startedAt: Date?
    private var wantsToRun = false
    /// Increases on every `stop()`, so an answer that arrives after one is ignored.
    private var generation = 0

    init(host: String, localPort: UInt16, onChange: @escaping @MainActor (State) -> Void) {
        self.host = host
        self.localPort = localPort
        self.onChange = onChange
    }

    func start() {
        wantsToRun = true
        launch()
    }

    func stop() {
        wantsToRun = false
        generation += 1
        retryTimer?.invalidate()
        retryTimer = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        state = .stopped
    }

    // MARK: - Internal

    /// Asks the far end — off the main actor — for the user's port and whether it
    /// is free, then spawns ssh with the forward.
    private func launch() {
        guard wantsToRun, process == nil else { return }
        state = .starting
        let host = self.host
        let expected = generation

        Task.detached(priority: .utility) { [weak self] in
            let prepared = RemoteCommand.runPythonForObject(on: host, script: RemoteInstallScripts.prepareTunnel)

            // The far side has just said the port is taken. Ask this Mac who is
            // holding it — here, off the main thread, before the hop, because
            // reading the process table is the kind of thing that must never
            // happen on the thread that draws the panel.
            //
            // This is the branch that actually runs. The tunnel asks the remote
            // machine what is bound *before* spawning ssh, so in the ordinary
            // case ssh is never started and its stderr never exists: a diagnosis
            // hung off that stderr would be correct, tested, and never reached.
            let localDiagnosis: String? = {
                guard case .success(let answer) = prepared,
                      let uid = (answer["uid"] as? NSNumber)?.intValue,
                      let bound = answer["bound"] as? [String], !bound.isEmpty
                else { return nil }
                return Self.localHolder(of: AppConfig.remotePort(forUID: uid))
            }()

            await MainActor.run { [weak self] in
                guard let self, self.wantsToRun, self.generation == expected else { return }
                switch prepared {
                case .failure(let error):
                    self.exited(status: 255, stderr: error.short)
                case .success(let answer):
                    if let problem = answer["problem"] as? String {
                        self.exited(status: -1, stderr: "~/.lampboard there \(problem)")
                    } else if let uid = (answer["uid"] as? NSNumber)?.intValue {
                        let port = AppConfig.remotePort(forUID: uid)
                        let bound = (answer["bound"] as? [String]) ?? []
                        if !bound.isEmpty {
                            // Somebody is there already: a ghost of the last
                            // connection, another Mac's tunnel, or a stranger.
                            // Asking anyway would fail after the fact; wait instead.
                            self.delay = AppConfig.remoteTunnelRetryMax
                            self.exited(
                                status: -1,
                                stderr: "port \(port) is taken there (\(bound.joined(separator: ", ")))",
                                culprit: localDiagnosis
                            )
                        } else {
                            self.spawn(port: port)
                        }
                    } else {
                        self.exited(status: -1, stderr: "the machine did not say who it is running as")
                    }
                }
            }
        }
    }

    private func spawn(port: UInt16) {
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = ["-N"] + RemoteCommand.hardening + [
            // A connection of its own, whatever the user's ssh config says: with
            // `ControlMaster auto` and `ControlPersist`, ssh hands the forward to
            // a shared master and exits 0, the tunnel reads as down while the
            // forward lives on in the master, and the next try finds its own
            // port taken (measured on the test VM, whose Lima config does that).
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "ConnectTimeout=\(Int(AppConfig.remoteProbeTimeout))",
            "-R", "127.0.0.1:\(port):127.0.0.1:\(localPort)",
            host,
        ]
        let errors = Pipe()
        ssh.standardOutput = FileHandle.nullDevice
        ssh.standardError = errors
        ssh.standardInput = FileHandle.nullDevice

        ssh.terminationHandler = { [weak self] finished in
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // Read here, on the background queue this handler already runs on,
            // and only when the failure is the one it explains: `ps` on the main
            // thread would be a freeze in the failure path, and the failure path
            // is where a freeze is least welcome.
            let culprit = TunnelRefusal.mentionsBindFailure(text)
                ? Self.localHolder(of: port)
                : nil
            Task { @MainActor [weak self] in
                self?.exited(status: finished.terminationStatus, stderr: text, culprit: culprit)
            }
        }

        do {
            try ssh.run()
        } catch {
            exited(status: -1, stderr: error.localizedDescription)
            return
        }
        process = ssh
        startedAt = Date()

        // ssh says nothing on success. If it is still running after the connect
        // timeout, a forward is in place — with ExitOnForwardFailure a refused bind
        // would already have ended it. *Where* it is bound is the node's to say.
        let launched = ssh
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.remoteProbeTimeout) { [weak self] in
            guard let self, self.process === launched, launched.isRunning else { return }
            self.verifyBind(port: port, expected: expected)
        }
    }

    /// The request was `127.0.0.1`. This is the answer.
    private func verifyBind(port: UInt16, expected: Int) {
        let host = self.host
        Task.detached(priority: .utility) { [weak self] in
            let answer = RemoteCommand.runPythonForObject(
                on: host, script: RemoteInstallScripts.checkTunnel(port: port)
            )
            await MainActor.run { [weak self] in
                guard let self, self.generation == expected,
                      let process = self.process, process.isRunning
                else { return }
                let bound = (try? answer.get())?["bound"] as? [String] ?? []
                let foreign = bound.filter { $0 != "127.0.0.1" && $0 != "::1" }
                if let address = foreign.first {
                    // Not ours to carry. Close it, do not retry, and say why.
                    self.wantsToRun = false
                    process.terminate()
                    self.process = nil
                    self.state = .exposed(on: address)
                    return
                }
                self.state = .up(since: self.startedAt ?? Date())
            }
        }
    }

    /// Who on this Mac is holding that port, if anyone. `nil` when the answer
    /// is not here.
    nonisolated private static func localHolder(of port: UInt16) -> String? {
        guard let listing = try? Command.run(
            "/bin/ps", ["-ax", "-o", "pid=,ppid=,command="],
            deadline: AppConfig.focusProbeTimeout
        ).output else { return nil }
        return TunnelRefusal.diagnosis(port: port, among: TunnelRefusal.parse(listing))
    }

    private func exited(status: Int32, stderr: String, culprit: String? = nil) {
        process = nil
        guard wantsToRun else { return }

        let lasted = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        // A tunnel that held for a minute earned a fresh start; one that died at
        // once keeps backing off.
        delay = lasted > 60 ? AppConfig.remoteTunnelRetryMin : min(delay * 2, AppConfig.remoteTunnelRetryMax)

        // The local answer wins when there is one: "the port could not be bound
        // there" is true and sends you to the wrong machine.
        state = .down(reason: culprit ?? Self.reason(status: status, stderr: stderr), retryIn: delay)

        retryTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.launch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private static func reason(status: Int32, stderr: String) -> String {
        let text = stderr
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Warning: Permanently added") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("remote port forwarding failed") {
            return "the port could not be bound there"
        }
        if text.localizedCaseInsensitiveContains("IDENTIFICATION HAS CHANGED") {
            return "host key changed: remove its old line from ~/.ssh/known_hosts"
        }
        if text.localizedCaseInsensitiveContains("permission denied") {
            return "ssh refused the key"
        }
        if text.isEmpty { return "ssh exited (\(status))" }
        return String(text.prefix(100))
    }
}
