import LampBoardCore
import Foundation

/// A real lampboard instance, started against a fake home.
///
/// This type exists for a precise reason, learned the hard way: window title
/// matching stayed broken for an entire working session **with ten green tests**,
/// because it had been verified with `osascript` from a terminal while the app
/// uses `NSAppleScript` — two transports that serialize lists differently. The
/// defect lived in the seam between the tested function and the real world, that
/// is, exactly where unit tests don't look.
///
/// Nothing is rebuilt in miniature here: the binary that will be installed is
/// launched, spoken to over the same HTTP the hooks use, and its answers are read.
final class AppUnderTest {

    /// Errors that stop the test run before it starts.
    enum LaunchError: Error, CustomStringConvertible {
        case binaryMissing(String)
        case neverBecameHealthy(String)

        var description: String {
            switch self {
            case .binaryMissing(let path):
                return "binary not found at \(path) — run `swift build` first"
            case .neverBecameHealthy(let detail):
                return "the app never answered on /health: \(detail)"
            }
        }
    }

    let home: URL
    let port: UInt16

    private let process = Process()
    private let binaryURL: URL
    private var token: String?

    /// - Parameter home: passing an existing home serves the cases that check
    ///   what happens on the **second start** — for instance whether the token is
    ///   reused or regenerated.
    init(binaryURL: URL, port: UInt16, home: URL? = nil) {
        self.binaryURL = binaryURL
        self.port = port
        self.home = home ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("lampboard-e2e-\(port)-\(ProcessInfo.processInfo.processIdentifier)")
    }

    // MARK: - Lifecycle

    /// Prepares the fake home, starts the process and waits for it to answer.
    func start() throws {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw LaunchError.binaryMissing(binaryURL.path)
        }

        try? FileManager.default.removeItem(at: home)
        // `.claude/projects` among them, and not as decoration: a real home has
        // it, and the rule that a session needs a conversation to earn a row
        // answers "keep the row" when it cannot look — a fake home missing the
        // folder was passing every session through the check it exists to make.
        for sub in [".claude/ide", ".claude/sessions", ".claude/projects", ".lampboard"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(sub), withIntermediateDirectories: true
            )
        }

        process.executableURL = binaryURL
        process.arguments = ["--headless", "--port", String(port), "--skip-setup-prompt"]

        var environment = ProcessInfo.processInfo.environment
        environment[AppConfig.homeOverrideVariable] = home.path
        process.environment = environment

        // The app must not write on the test run's terminal: what matters is read
        // from /sessions, not from stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        try waitUntilHealthy()
        token = readToken()
    }

    /// Prepares and starts reusing a home that already exists.
    /// It deletes nothing: that is the whole point.
    func startReusingHome() throws {
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw LaunchError.binaryMissing(binaryURL.path)
        }

        process.executableURL = binaryURL
        process.arguments = ["--headless", "--port", String(port), "--skip-setup-prompt"]

        var environment = ProcessInfo.processInfo.environment
        environment[AppConfig.homeOverrideVariable] = home.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        try waitUntilHealthy()
        token = readToken()
    }

    /// Stops the process without touching the home.
    func stopKeepingHome() {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Stops the process and deletes the fake home.
    func stop() {
        if process.isRunning {
            process.terminate()
            // One second is more than enough for an app that only has to close a
            // listener; past that, we insist.
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Queries

    /// Sends a hook payload exactly the way the installed script does.
    /// - Parameter host: what the script installed on another machine adds, so
    ///   the signal is known to have come through the tunnel.
    @discardableResult
    func sendHook(
        _ payload: [String: Any], entrypoint: String? = "claude-vscode", host: String? = nil,
        harness: String? = nil
    ) -> Int {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var request = URLRequest(url: url(AppConfig.signalPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let entrypoint {
            request.setValue(entrypoint, forHTTPHeaderField: "X-Claude-Entrypoint")
        }
        if let host {
            request.setValue(host, forHTTPHeaderField: AppConfig.remoteHostHeader)
        }
        // The header the installed script adds. Only the hook knows for certain
        // which agent invoked it, and a Codex signal that arrives without it is
        // read as Claude Code's — which would quietly rewrite the row's harness.
        if let harness {
            request.setValue(harness, forHTTPHeaderField: AppConfig.harnessHeader)
        }
        request.httpBody = body
        return perform(request).status
    }

    /// Reads the column from the authenticated endpoint.
    func sessions() -> SessionsResponse? {
        var request = URLRequest(url: url(AppConfig.sessionsPath))
        request.httpMethod = "GET"
        if let token { request.setValue(token, forHTTPHeaderField: AccessToken.headerName) }
        let result = perform(request)
        guard result.status == 200 else { return nil }
        return try? SessionsCodec.decode(result.body)
    }

    /// Performs a raw request: needed by the cases that check the refusals.
    func raw(
        method: String,
        path: String,
        token overrideToken: String?? = nil,
        body: String? = nil
    ) -> (status: Int, body: String) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        // An outer `nil` means "use the real one"; `.some(nil)` means
        // "don't send one at all".
        let chosen = overrideToken ?? token
        if let chosen { request.setValue(chosen, forHTTPHeaderField: AccessToken.headerName) }
        if let body { request.httpBody = Data(body.utf8) }
        let result = perform(request)
        return (result.status, String(data: result.body, encoding: .utf8) ?? "")
    }

    /// The session with that id, if the column holds it.
    func session(id: String) -> SessionSnapshot? {
        sessions()?.sessions.first { $0.id == id }
    }

    /// The status of a session, or `"absent"` when the row isn't there.
    /// The sentinel value avoids an optional in every assertion.
    func status(of id: String) -> String {
        session(id: id)?.status ?? "absent"
    }

    var tokenValue: String? { token }

    /// The binary under test, for the cases that have to start it themselves.
    var binaryPath: URL { binaryURL }

    var tokenFileURL: URL {
        home.appendingPathComponent(".lampboard/token")
    }

    /// Runs one of the binary's terminal commands, against the same fake home.
    @discardableResult
    func runCommand(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment[AppConfig.homeOverrideVariable] = home.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        guard (try? process.run()) != nil else { return (-1, "launch failed") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs the generated hook script, giving it the payload on stdin — that is,
    /// exactly the way Claude Code runs it.
    @discardableResult
    func runHookScript(
        payload: [String: Any],
        entrypoint: String = "claude-vscode"
    ) -> Int32 {
        let script = home.appendingPathComponent(".lampboard/hook.sh")
        let process = Process()
        process.executableURL = script

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint
        process.environment = environment

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return -1 }
        input.fileHandleForWriting.write(
            (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        )
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The contents of `settings.json` in the fake home.
    func claudeSettings() -> [String: Any] {
        let url = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    // MARK: - Filesystem fixtures

    /// Writes a lock file simulating an open IDE window.
    func writeIDELock(port lockPort: Int, folders: [String], ideName: String = "Visual Studio Code") {
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaceFolders": folders,
            "ideName": ideName,
            "transport": "ws",
        ]
        let url = home.appendingPathComponent(".claude/ide/\(lockPort).lock")
        try? JSONSerialization.data(withJSONObject: payload).write(to: url)
    }

    /// Writes a live session file. The PID is the test run's own, which is alive
    /// by definition: the simplest way to get past `kill(pid, 0)`.
    func writeLiveSession(
        sessionId: String,
        cwd: String,
        entrypoint: String = "claude-vscode",
        name: String? = nil,
        pid: Int32? = nil
    ) {
        var payload: [String: Any] = [
            "pid": pid ?? ProcessInfo.processInfo.processIdentifier,
            "sessionId": sessionId,
            "cwd": cwd,
            "entrypoint": entrypoint,
            "kind": "interactive",
        ]
        if let name { payload["name"] = name }
        let url = home.appendingPathComponent(
            ".claude/sessions/\(payload["pid"] as? Int32 ?? 0).json"
        )
        try? JSONSerialization.data(withJSONObject: payload).write(to: url)
    }

    /// A transcript with a title, where the app expects to find it for that
    /// session and folder — what names a terminal row.
    /// - Parameter path: where to write it; by default where the app derives it
    ///   from the session id and folder. The hook fixtures name `/tmp/<id>.jsonl`,
    ///   and a hook's word wins over the derivation.
    func writeTranscript(sessionId: String, cwd: String, title: String, at path: String? = nil) {
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? TranscriptLocator.candidateURL(sessionId: sessionId, cwd: cwd, home: home)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let record: [String: Any] = ["type": "ai-title", "sessionId": sessionId, "aiTitle": title]
        let line = (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
        try? (line + Data("\n".utf8)).write(to: url)
    }

    func removeLiveSessions() {
        let directory = home.appendingPathComponent(".claude/sessions")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries { try? FileManager.default.removeItem(at: entry) }
    }

    /// Waits for a condition to become true, or gives up.
    ///
    /// The periodic realignment is asynchronous: without waiting, the test would
    /// check the state of a moment earlier and fail intermittently, which is the
    /// best way to make people stop trusting the tests.
    @discardableResult
    func waitUntil(
        timeout: TimeInterval = 12,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(120_000)
        }
        return condition()
    }

    /// Answers whether a condition held for long enough that its opposite would
    /// have happened by now.
    ///
    /// The mirror of `waitUntil`, and it cannot be written in terms of it. A row
    /// that must **not** appear offers no moment to wait for, so the only honest
    /// check is to let the sweeps go by and keep looking. Two of them plus a
    /// second, so a probe that was already in flight when the fixture landed
    /// still gets one whole pass afterwards.
    ///
    /// Without this an absence is asserted the instant the fixture is written,
    /// which every wrong implementation also passes.
    ///
    /// It looks as often as the question can be asked, and that is deliberate.
    /// The first version slept 200 milliseconds between looks and passed against
    /// a defect that took rows away for **eighty**: the row was pruned at the end
    /// of one sweep and re-adopted when a probe on another actor answered, and a
    /// sampler that blinks slower than the thing it is watching sees a panel that
    /// never changed. Each look is an HTTP round trip of its own, roughly 25
    /// milliseconds, so the gap is already smaller than any flicker a person
    /// could see.
    @discardableResult
    func holdsThroughTwoSweeps(_ condition: () -> Bool) -> Bool {
        let deadline = Date()
            .addingTimeInterval(AppConfig.liveSessionPollInterval * 2 + 1)
        while Date() < deadline {
            if !condition() { return false }
        }
        return condition()
    }

    // MARK: - Internal

    private func url(_ path: String) -> URL {
        URL(string: "http://\(AppConfig.listenHost):\(port)\(path)")!
    }

    private func readToken() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmed
    }

    private func waitUntilHealthy() throws {
        let deadline = Date().addingTimeInterval(15)
        var lastDetail = "no attempt made"

        while Date() < deadline {
            guard process.isRunning else {
                throw LaunchError.neverBecameHealthy(
                    "the process exited with code \(process.terminationStatus)"
                )
            }
            var request = URLRequest(url: url("/health"))
            request.timeoutInterval = 1
            let result = perform(request)
            if result.status == 200 { return }
            lastDetail = "last HTTP status \(result.status)"
            usleep(150_000)
        }
        throw LaunchError.neverBecameHealthy(lastDetail)
    }

    private func perform(_ request: URLRequest) -> (status: Int, body: Data) {
        var mutable = request
        if mutable.timeoutInterval > 5 { mutable.timeoutInterval = 5 }

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var body = Data()

        URLSession.shared.dataTask(with: mutable) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 8)
        return (status, body)
    }
}
