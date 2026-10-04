import LampBoardCore
import Foundation

/// The trial: this app, started on a home of its own, playing the invented
/// sessions of `DemoScript` (D64).
///
/// It sets the stage the way `make-screenshots.sh` does — an editor lock per
/// project, a live process per session, a transcript with a title and a
/// context reading — and then plays the beats as hook payloads posted to its
/// own server, so every colour on screen is one the reducer really produced.
///
/// **Only under `LAMPBOARD_HOME`.** The stage writes session files and
/// transcripts into the home it runs in; on the real home it would put invented
/// sessions into the user's `~/.claude`. Without the override, `--trial` is
/// refused and the app starts as itself.
enum TrialStage {

    struct Mode {
        /// How much faster than written the script plays: 1 for a person,
        /// more for the end-to-end suite and the screenshots.
        let pace: Double
    }

    static var mode: Mode? {
        let arguments = CommandLine.arguments
        guard arguments.contains("--trial"), AppConfig.isUsingHomeOverride else { return nil }
        let pace = arguments.firstIndex(of: "--trial-pace").flatMap { index in
            index + 1 < arguments.count ? Double(arguments[index + 1]) : nil
        }
        return Mode(pace: max(1, min(pace ?? 1, 100)))
    }

    /// A process standing in for each session's `claude`: the sweep keeps only
    /// rows whose pid answers, and one pid cannot hold two session files.
    private static var holders: [Process] = []

    static var work: URL { AppConfig.homeDirectory.appendingPathComponent("work", isDirectory: true) }

    // MARK: - The stage

    static func prepare(_ script: DemoScript, preferences: Preferences, files: LampMasterFiles, now: Date = Date()) {
        let manager = FileManager.default
        let claude = AppConfig.claudeDirectory
        for folder in ["ide", "sessions", "projects"] {
            try? manager.createDirectory(at: claude.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (index, session) in script.sessions.enumerated() {
            let path = work.appendingPathComponent(session.folder).path
            try? manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            write(["pid": Int(getpid()), "workspaceFolders": [path], "ideName": "Visual Studio Code", "transport": "ws"],
                  to: claude.appendingPathComponent("ide/\(41_000 + index).lock"))
            guard let holder = hold() else { continue }
            write(["pid": Int(holder), "sessionId": session.id, "cwd": path, "entrypoint": "claude-vscode", "kind": "interactive"],
                  to: claude.appendingPathComponent("sessions/\(holder).json"))
            writeTranscript(session, at: path, now: now)
        }
        seedLampMaster(script, preferences: preferences, files: files, now: now)
    }

    /// LampMaster's card for the last step: switched on in the trial's own
    /// preferences, with one round already run. No `claude` runs in a trial.
    private static func seedLampMaster(_ script: DemoScript, preferences: Preferences, files: LampMasterFiles, now: Date) {
        preferences.lampMasterEnabled = true
        files.append(LampMasterRound(at: now, trigger: .timer, outcome: .ran, model: "opus", sessions: script.sessions.count,
                                     proposed: 1, shown: 1, digest: "trial"), now: now)
        files.save(LampMasterLedger.entries(for: [script.suggestion], at: now))
    }

    private static func writeTranscript(_ session: DemoScript.Session, at path: String, now: Date) {
        let folder = AppConfig.claudeDirectory.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.directoryName(forWorkspace: path))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now)
        let records: [[String: Any]] = [
            ["type": "ai-title", "aiTitle": session.title, "sessionId": session.id],
            ["type": "assistant", "timestamp": stamp, "cwd": path, "entrypoint": "claude-vscode",
             "message": ["role": "assistant", "model": session.model, "content": [["type": "text", "text": "Ready."]],
                         "usage": ["input_tokens": 1_000, "cache_read_input_tokens": 120_000, "cache_creation_input_tokens": 0,
                                   "output_tokens": 300]]],
        ]
        let text = records.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        try? text.write(to: folder.appendingPathComponent("\(session.id).jsonl"), atomically: true, encoding: .utf8)
    }

    private static func hold() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["86400"]
        guard (try? process.run()) != nil else { return nil }
        holders.append(process)
        return process.processIdentifier
    }

    private static func write(_ object: [String: Any], to url: URL) {
        try? JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    // MARK: - The play

    /// Posts every beat to this app's own `/signal`, at its time.
    static func play(_ script: DemoScript, port: UInt16, pace: Double) {
        for beat in script.beats {
            let payload = script.payload(for: beat, work: work.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + beat.at / pace) {
                post(payload, port: port)
            }
        }
    }

    private static func post(_ payload: [String: Any], port: UInt16) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: URL(string: "http://\(AppConfig.listenHost):\(port)\(AppConfig.signalPath)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - The end

    /// The holders go, and the home with them: a trial leaves nothing behind.
    static func tearDown() {
        holders.forEach { $0.terminate() }
        holders.removeAll()
        guard AppConfig.isUsingHomeOverride, AppConfig.homeDirectory.lastPathComponent.hasPrefix(homePrefix) else { return }
        try? FileManager.default.removeItem(at: AppConfig.homeDirectory)
    }

    /// The temporary homes `lampboard tour` creates are named so, and only those
    /// are ever deleted: a trial started by hand on another home keeps it.
    static let homePrefix = "lampboard-trial-"
}
