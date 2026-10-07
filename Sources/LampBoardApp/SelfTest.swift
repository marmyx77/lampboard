import LampBoardCore
import Foundation

/// Verifies the hook → server → workspace resolution chain end to end, without
/// opening the interface.
///
/// It exists to answer the question you ask yourself when a traffic light doesn't
/// come on: is transport failing, or decoding, or window recognition? Trying to
/// guess that from an unlit dot doesn't work.
enum SelfTest {

    /// - Parameter cwd: folder to use in the probe signal.
    static func run(port: UInt16, cwd: String = FileManager.default.currentDirectoryPath) -> Int32 {
        var failures = 0

        print("LampBoard self-diagnosis\n")

        // 1. Is somebody already there?
        //
        // Asked before trying to bind, because `SignalServer.start()` returns
        // before the listener is ready: with the panel running it announced a
        // server that had in fact failed with "Address already in use", the probe
        // then reached the *panel*, and the test concluded "the signal never
        // reached the handler". A false alarm, raised at the one moment somebody
        // runs a diagnosis — when they already suspect something is broken.
        if let running = probeRunningInstance(port: port) {
            print("• a LampBoard is already listening on \(AppConfig.listenHost):\(port)")
            switch running {
            case .status(204):
                print("✓ the running panel accepts signals (HTTP 204)")
            case .status(let code):
                print("✗ the running panel answered HTTP \(code) to a signal")
                failures += 1
            case .failed(let reason):
                print("✗ the running panel refused the probe: \(reason)")
                failures += 1
            }
            print("  the loop test needs the port to itself, so it is not run here.")
            print("  Quit the panel and run this again to check the whole chain.")
            failures += reportEnvironment(cwd: cwd)
            return finish(failures)
        }

        // 2. Can the server open the port?
        let received = Box<HookSignal?>(nil)
        let semaphore = DispatchSemaphore(value: 0)

        let server = SignalServer(
            port: port,
            onSignal: { signal in
                received.value = signal
                semaphore.signal()
            },
            onError: { message in
                print("  server: \(message)")
            }
        )

        do {
            try server.start()
            print("✓ server listening on \(AppConfig.listenHost):\(port)")
        } catch {
            print("✗ the server won't start: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            print("\n  If the panel is already running the port is taken: that's normal.")
            return 1
        }
        defer { server.stop() }

        // 3. Does a signal cross HTTP and get decoded?
        let payload = probePayload(cwd: cwd)
        switch post(payload, port: port) {
        case .failed(let reason):
            print("✗ the probe POST failed: \(reason)")
            failures += 1
        case .status(204):
            print("✓ the server accepts signals (HTTP 204)")
        case .status(let code):
            print("✗ unexpected response from the server: HTTP \(code)")
            failures += 1
        }

        if semaphore.wait(timeout: .now() + 3) == .success, let signal = received.value {
            print("✓ signal decoded: \(signal.event.rawValue) from \(signal.cwd)")
        } else {
            print("✗ the signal never reached the handler")
            failures += 1
        }

        failures += reportEnvironment(cwd: cwd)
        return finish(failures)
    }

    /// Everything that is true whether or not this process owns the port.
    ///
    /// Split out so the two paths — panel running, panel not running — report the
    /// same things. A diagnosis that says less when the app is running says least
    /// exactly when it is needed most.
    /// The second harness, checked on its own.
    ///
    /// It used to say "All good" without ever looking at Codex, which is the worst
    /// possible answer from a diagnosis: somebody runs this **because** something
    /// is wrong, and a green line about the half that works sends them away.
    ///
    /// Three things are checked and one is deliberately not. Whether Codex is here
    /// at all; whether our hooks are registered; and whether any session is
    /// actually visible. Trust is the one this cannot see: it lives inside Codex's
    /// own configuration and is granted by a person typing `/hooks`, so the line
    /// says that rather than guessing.
    private static func reportCodex() -> Int {
        print("\nCodex")
        guard FileManager.default.fileExists(atPath: AppConfig.codexDirectory.path) else {
            print("• not installed on this machine, so nothing about it is wrong")
            return 0
        }

        var failures = 0
        let events = HookInstaller.codex().installedEvents()
        if events.isEmpty {
            print("✗ our hooks are not registered in \(AppConfig.codexHooksURL.path)")
            print("  Run: lampboard install-hooks")
            failures += 1
        } else {
            print("✓ hooks registered: \(events.joined(separator: ", "))")
            print("• trust cannot be read from here: run /hooks inside Codex to confirm")
        }

        switch CodexProcessScanner().scan() {
        case .unavailable(let reason):
            // A reason to go looking, and told apart from "none" on purpose: this
            // one means the panel is blind, not that the machine is quiet.
            print("✗ live sessions could not be read: \(reason)")
            failures += 1
        case .observed(let evidence) where evidence.isEmpty:
            print("• no Codex session is holding a rollout open right now")
        case .observed(let evidence):
            print("✓ \(evidence.count) live session\(evidence.count == 1 ? "" : "s") found without hooks")
            for item in evidence {
                print("    · \(item.meta.cwd)  [\(item.surface.label)]")
            }
        }
        return failures
    }

    private static func reportEnvironment(cwd: String) -> Int {
        var failures = 0
        failures += reportCodex()

        // 4. Does the current folder match a VS Code window?
        let windows = IDEWindowReader().readWindows()
        let fresh = windows.filter { $0.isSupported }
        print("\nVS Code windows with Claude Code active: \(fresh.count)")

        if let workspace = WorkspaceResolver.resolve(cwd: cwd, in: windows, at: Date()) {
            print("✓ \(cwd)\n  → workspace “\(workspace.name)”")
        } else {
            print("✗ no VS Code window contains \(cwd)")
            print("  (normal if you are running the command from an external terminal)")
            failures += 1
        }

        // 4. Are the permissions to activate windows in place? There are two, distinct.
        if VSCodeFocuser.hasAccessibilityPermission {
            print("✓ Accessibility permission granted")
        } else {
            print("✗ Accessibility permission missing")
            print("  System Settings › Privacy & Security › Accessibility")
            failures += 1
        }

        if let error = VSCodeFocuser.checkAutomationPermission() {
            print("✗ Automation permission: \(error.shortDescription)")
            print("  System Settings › Privacy & Security › Automation")
            print("  → lampboard → System Events")
            failures += 1
        } else {
            print("✓ Automation permission (System Events) granted")
        }

        if !VSCodeFocuser.hasAccessibilityPermission
            || VSCodeFocuser.checkAutomationPermission() != nil {
            print("  Without either of the two the click falls back to `open`: VS Code")
            print("  still comes to the front, but it may open a new window.")
        }

        // 5. Are the hooks registered?
        let installer = HookInstaller()
        let events = installer.installedEvents()
        if events.isEmpty {
            print("✗ no hooks registered: run `lampboard install-hooks`")
            failures += 1
        } else {
            print("✓ hooks registered for: \(events.joined(separator: ", "))")
        }

        return failures
    }

    private static func finish(_ failures: Int) -> Int32 {
        print("\n" + String(repeating: "─", count: 56))
        switch failures {
        case 0: print("All good.")
        case 1: print("1 problem found.")
        default: print("\(failures) problems found.")
        }
        return failures == 0 ? 0 : 1
    }


    // MARK: - Helpers

    /// Is a lampboard already answering on this port?
    ///
    /// Asked by sending it a real probe signal rather than by opening a socket:
    /// the useful answer is not "something is bound there" but "the thing bound
    /// there behaves like our server", and the second is what the user needs to
    /// know. `nil` means nobody is home and the loop test can proceed.
    private static func probeRunningInstance(port: UInt16) -> ProbeResult? {
        guard let url = URL(string:
            "http://\(AppConfig.listenHost):\(port)\(AppConfig.healthPath)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        let answered = Box<Bool>(false)
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            answered.value = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)

        guard answered.value else { return nil }
        return post(probePayload(cwd: FileManager.default.currentDirectoryPath), port: port)
    }

    private static func probePayload(cwd: String) -> Data {
        let object: [String: Any] = [
            "session_id": "self-diagnosis",
            "hook_event_name": "SessionStart",
            "cwd": cwd,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Outcome of the probe POST.
    private enum ProbeResult {
        case status(Int)
        case failed(String)
    }

    private static func post(_ body: Data, port: UInt16) -> ProbeResult {
        guard let url = URL(
            string: "http://\(AppConfig.listenHost):\(port)\(AppConfig.signalPath)"
        ) else {
            return .failed("invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-vscode", forHTTPHeaderField: "X-Claude-Entrypoint")
        request.timeoutInterval = 3

        let result = Box<ProbeResult>(.failed("no response within the timeout"))
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                result.value = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                result.value = .status(http.statusCode)
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return result.value
    }
}

/// Reference container used to get a value out of a callback.
/// It serves the synchronous diagnostics only: the rest of the code mutates nothing.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
