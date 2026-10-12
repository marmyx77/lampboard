import Foundation
import LampBoardCore
import Security

/// LampMaster as a Claude Code session LampBoard hosts (hub-terminale R10–R13):
/// started, or taken up again, in tmux in its own folder, shown in the Hub's
/// centre like any session, and given hands across the others through the
/// `lampboard` MCP server of that folder.
///
/// The hands answer only the session LampBoard started as LampMaster, and every
/// one that acts goes through Claude Code's own question to the person first
/// (`LampMasterHome.settings` allows ahead only what reads).
@MainActor
final class LampMasterConductor {

    private let store: StateStore
    private let launcher: SessionLauncher
    private let target: (String) -> LiveTarget?
    private let openInHub: (String) -> Void
    private let port: UInt16

    static let sessionKey = "lampmaster.sessionId"

    init(store: StateStore, launcher: SessionLauncher, port: UInt16,
         target: @escaping (String) -> LiveTarget?, openInHub: @escaping (String) -> Void) {
        self.store = store
        self.launcher = launcher
        self.port = port
        self.target = target
        self.openInHub = openInHub
    }

    /// The conversation LampBoard started as LampMaster, if any.
    var sessionId: String? { Preferences.sharedDefaults.string(forKey: Self.sessionKey) }

    static var folder: URL { AppConfig.supportDirectory.appendingPathComponent(LampMasterHome.folderName, isDirectory: true) }

    /// Starts LampMaster, or takes its conversation up again; shows it.
    func start(failed: @escaping (String) -> Void) {
        let folder = Self.folder.path
        // Running, or starting: it is shown, never started twice, and its folder
        // (its key) is left as its server read it.
        if let id = sessionId, launcher.isStarting(id) || SessionLauncher.busy(id, host: nil, store: store) != nil { return }
        do { try prepare() } catch {
            return failed("LampBoard could not prepare LampMaster's folder: \(error.localizedDescription)")
        }
        let resumable = sessionId.flatMap { id in
            FileManager.default.fileExists(atPath: TranscriptLocator.candidateURL(sessionId: id, cwd: folder).path) ? id : nil
        }
        let start: NewSession.Start = resumable.map { .resume(sessionId: $0) } ?? .new(sessionId: SessionLauncher.newSessionId())
        Preferences.sharedDefaults.set(start.sessionId, forKey: Self.sessionKey)
        // Not revealed as a session of its own: the Hub shows it on LampMaster's row.
        launcher.launch(folder: folder, host: nil, start: start, name: "LampMaster", reveal: false) { if let reason = $0 { failed(reason) } }
    }

    /// The key of this start of LampMaster, given to its server alone through
    /// its folder's `.mcp.json` (owner-only); the hands answer nothing without it.
    /// Kept in an owner-only file too: LampBoard may restart while LampMaster runs.
    private lazy var key: String? = (try? String(contentsOf: Self.keyFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

    static var keyFile: URL { AppConfig.supportDirectory.appendingPathComponent("lampmaster.key") }

    /// What LampMaster's folder holds: who it is, its server, its settings.
    /// The person's own `CLAUDE.local.md` beside them is never touched.
    private func prepare() throws {
        let folder = Self.folder
        let settings = folder.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data(LampMasterHome.instructions.utf8).write(to: folder.appendingPathComponent("CLAUDE.md"), options: .atomic)
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.featureUnsupported)
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        let config = folder.appendingPathComponent(".mcp.json")
        try LampMasterHome.mcpConfig(executable: executable, port: port, defaultPort: AppConfig.listenPort, key: key)
            .write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        FileManager.default.createFile(atPath: Self.keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        self.key = key
        try LampMasterHome.settings().write(to: settings.appendingPathComponent("settings.json"), options: .atomic)
    }

    // MARK: - The hands

    /// `POST /lampmaster/hands`, from the server's queue: answered on the main
    /// actor, the wait bounded.
    nonisolated func answer(_ body: Data) -> Data {
        let done = DispatchSemaphore(value: 0)
        let reply = Reply()
        Task { @MainActor in
            reply.value = await self.hands(body)
            done.signal()
        }
        guard done.wait(timeout: .now() + 50) == .success else { return Self.encode("LampBoard did not answer in time.", isError: true) }
        return Self.encode(reply.value.text, isError: reply.value.isError)
    }

    private final class Reply: @unchecked Sendable { var value: (text: String, isError: Bool) = ("", true) }

    nonisolated static func encode(_ text: String, isError: Bool) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["text": text, "isError": isError])) ?? Data("{}".utf8)
    }

    func hands(_ body: Data) async -> (text: String, isError: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = object["tool"] as? String, let tool = LampMasterHands.Tool(rawValue: name)
        else { return ("Unknown tool.", true) }
        // Only LampMaster's own session: the server is in its folder alone and
        // carries the key of this start; a session id is no secret (it is in `ps`).
        guard let me = sessionId, (object["session"] as? String) == me, let key,
              let given = object["key"] as? String, Self.same(given, key) else {
            return ("These tools belong to LampMaster's own session, started by LampBoard.", true)
        }
        let arguments = object["arguments"] as? [String: Any] ?? [:]
        let string = { (key: String) in (arguments[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? "" }
        let all = facts()
        switch tool {
        case .sessions:
            return (LampMasterHands.list(all), false)
        case .readSession:
            guard let found = LampMasterHands.find(string("session"), in: all) else { return (unknown(string("session")), true) }
            return (await read(found, messages: arguments["messages"] as? Int ?? 6), false)
        case .sendToSession:
            guard let found = LampMasterHands.find(string("session"), in: all) else { return (unknown(string("session")), true) }
            return await send(LampMasterHands.framed(string("text")), to: found)
        case .stopSession:
            guard let found = LampMasterHands.find(string("session"), in: all) else { return (unknown(string("session")), true) }
            if case .refuse(let why) = LampMasterHands.canStop(found) { return (why, true) }
            guard let place = place(found.id) else { return ("LampBoard has no terminal into \(found.name).", true) }
            let done = await run(HandsScript.stop(target: place.target), on: place.host) != nil
            return done ? ("Esc pressed in \(found.name).", false) : ("tmux did not take the key.", true)
        case .startSession:
            let folder = string("folder"), host = string("host").nilIfEmpty, resume = string("resume").nilIfEmpty
            guard ProjectList.isValid(path: folder, host: host) else { return ("A folder is an absolute path, on this Mac or a machine in Settings › Other Macs.", true) }
            let start: NewSession.Start = resume.map { .resume(sessionId: $0) } ?? .new(sessionId: SessionLauncher.newSessionId())
            // Its outcome, not a guess: a start here takes tmux's word, one there ssh's.
            let refusal: String? = await withCheckedContinuation { continuation in
                launcher.launch(folder: folder, host: host, start: start, name: nil, reveal: false) { continuation.resume(returning: $0) }
            }
            if let refusal { return (refusal, true) }
            return ("Started in \((folder as NSString).lastPathComponent)\(host.map { " on \($0)" } ?? ""), id \(start.sessionId.prefix(8)).", false)
        case .openInHub:
            guard let found = LampMasterHands.find(string("session"), in: all) else { return (unknown(string("session")), true) }
            openInHub(found.id)
            return ("\(found.name) is open in the Hub.", false)
        }
    }

    /// Compares in constant time: how much of a key matched is never told by when.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func unknown(_ query: String) -> String {
        "No single session has an id starting with \"\(query.prefix(40))\". Ask for the list with sessions."
    }

    /// Every session as LampMaster sees it.
    private func facts(now: Date = Date()) -> [LampMasterHands.Facts] {
        store.sessions.map { session in
            let surface: LampMasterHands.Surface
            switch target(session.id) {
            case .tmux?: surface = .tmux
            case .job?: surface = .background
            default:
                switch session.entrypoint {
                case "claude-vscode": surface = .vscode
                case "claude-desktop": surface = .app
                default: surface = .other
                }
            }
            return LampMasterHands.Facts(
                id: session.id, name: session.displayName, project: session.workspace.name, host: session.workspace.host,
                surface: surface, status: session.status, minutes: max(0, Int(now.timeIntervalSince(session.updatedAt) / 60)),
                isLampMaster: session.id == sessionId)
        }
    }

    private func place(_ id: String) -> (host: String?, target: String)? {
        guard case .tmux(let host, let place, _)? = target(id) else { return nil }
        return (host, place.target)
    }

    private func read(_ session: LampMasterHands.Facts, messages: Int) async -> String {
        guard let state = store.state.sessions[session.id] else { return "No transcript for \(session.name)." }
        let tail: String?
        if let host = state.workspace.host {
            let cwd = store.remoteSessions[host]?.first(where: { $0.sessionId == session.id })?.cwd ?? state.workspace.path
            let path = LiveChatSource.remotePath(sessionId: session.id, cwd: cwd)
            tail = await ProjectSource.ssh(host, "tail -c 262144 -- \"$HOME\"/\(NewSession.shellQuoted(path)) 2>/dev/null")
        } else {
            let url = state.transcriptPath.map { URL(fileURLWithPath: $0) }
                ?? TranscriptLocator.candidateURL(sessionId: session.id, cwd: state.workspace.path)
            tail = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
                return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
            }.value
        }
        guard let tail else { return "LampBoard could not read \(session.name)'s transcript." }
        // Decoded away from the main actor: a quarter of a megabyte of JSON lines.
        let digest = await Task.detached(priority: .userInitiated) { LampMasterHands.digest(tail: tail, messages: messages) }.value
        return "\(session.name) (\(session.id.prefix(8))):\n" + digest
    }

    private func send(_ text: String, to session: LampMasterHands.Facts) async -> (text: String, isError: Bool) {
        if case .refuse(let why) = LampMasterHands.canSend(session, promptEmpty: true) { return (why, true) }
        guard let place = place(session.id) else { return ("LampBoard has no terminal into \(session.name).", true) }
        // Its prompt, read now: nothing the person typed is mixed into, and
        // nothing goes into a shell Claude Code left behind.
        guard let look = await run(HandsScript.look(target: place.target), on: place.host).flatMap(HandsScript.parseLook) else {
            return ("LampBoard could not read \(session.name)'s terminal.", true)
        }
        guard !HandsScript.isShell(look.command) else { return ("Claude Code is no longer running in \(session.name)'s terminal.", true) }
        let empty = PromptLine.isEmpty(lines: look.lines, cursorX: look.x, cursorY: look.y)
        if case .refuse(let why) = LampMasterHands.canSend(session, promptEmpty: empty) { return (why, true) }
        // The same cursor is checked again by the script that pastes, at once.
        let buffer = String(UUID().uuidString.lowercased().prefix(8))
        guard let script = HandsScript.send(target: place.target, cursorX: look.x, cursorY: look.y, buffer: buffer),
              await run(script, on: place.host, input: Data(text.utf8)) != nil else {
            return ("\(session.name)'s prompt changed just before sending: nothing was sent.", true)
        }
        return ("Sent to \(session.name).", false)
    }

    /// A tmux script here, or on `host` through the panel's ssh.
    private func run(_ script: String, on host: String?, input: Data? = nil) async -> String? {
        // Under `sh`, whatever login shell the other machine has (D133).
        if let host { return await ProjectSource.ssh(host, NewSession.posix(script), input: input) }
        guard let tmux = LocalTmuxPlaces.executable() else { return nil }
        let path = (tmux as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
        return await ProjectSource.run("/usr/bin/env", ["PATH=\(path)", "/bin/sh", "-c", script], input: input)
    }
}
