import Foundation
import LampBoardCore

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
        do { try prepare() } catch {
            return failed("LampBoard could not prepare LampMaster's folder: \(error.localizedDescription)")
        }
        let folder = Self.folder.path
        // Running already: it is shown, never started twice.
        if let id = sessionId, SessionLauncher.busy(id, host: nil, store: store) != nil { return }
        let resumable = sessionId.flatMap { id in
            FileManager.default.fileExists(atPath: TranscriptLocator.candidateURL(sessionId: id, cwd: folder).path) ? id : nil
        }
        let start: NewSession.Start = resumable.map { .resume(sessionId: $0) } ?? .new(sessionId: SessionLauncher.newSessionId())
        Preferences.sharedDefaults.set(start.sessionId, forKey: Self.sessionKey)
        // Not revealed as a session of its own: the Hub shows it on LampMaster's row.
        launcher.launch(folder: folder, host: nil, start: start, name: "LampMaster", reveal: false, failed: failed)
    }

    /// What LampMaster's folder holds: who it is, its server, its settings.
    /// The person's own `CLAUDE.local.md` beside them is never touched.
    private func prepare() throws {
        let folder = Self.folder
        let settings = folder.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data(LampMasterHome.instructions.utf8).write(to: folder.appendingPathComponent("CLAUDE.md"), options: .atomic)
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        try LampMasterHome.mcpConfig(executable: executable, port: port, defaultPort: AppConfig.listenPort)
            .write(to: folder.appendingPathComponent(".mcp.json"), options: .atomic)
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
        // Only LampMaster's own session: the server is in its folder alone, and
        // a session elsewhere that named it would still be refused here.
        guard let me = sessionId, (object["session"] as? String) == me else {
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
            var refusal: String?
            launcher.launch(folder: folder, host: host, start: start, name: nil, reveal: false) { refusal = $0 }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let refusal { return (refusal, true) }
            return ("Started in \((folder as NSString).lastPathComponent)\(host.map { " on \($0)" } ?? ""), id \(start.sessionId.prefix(8)).", false)
        case .openInHub:
            guard let found = LampMasterHands.find(string("session"), in: all) else { return (unknown(string("session")), true) }
            openInHub(found.id)
            return ("\(found.name) is open in the Hub.", false)
        }
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
        return "\(session.name) (\(session.id.prefix(8))):\n" + LampMasterHands.digest(tail: tail, messages: messages)
    }

    private func send(_ text: String, to session: LampMasterHands.Facts) async -> (text: String, isError: Bool) {
        if case .refuse(let why) = LampMasterHands.canSend(session, promptEmpty: true) { return (why, true) }
        guard let place = place(session.id) else { return ("LampBoard has no terminal into \(session.name).", true) }
        // Its prompt, read now: nothing the person typed is mixed into.
        let look = await run(HandsScript.look(target: place.target), on: place.host).flatMap(HandsScript.parseLook)
        let empty = look.map { PromptLine.isEmpty(lines: $0.lines, cursorX: $0.x, cursorY: $0.y) }
        if case .refuse(let why) = LampMasterHands.canSend(session, promptEmpty: empty) { return (why, true) }
        guard await run(HandsScript.send(target: place.target), on: place.host, input: Data(text.utf8)) != nil else {
            return ("tmux did not take the message.", true)
        }
        return ("Sent to \(session.name).", false)
    }

    /// A tmux script here, or on `host` through the panel's ssh.
    private func run(_ script: String, on host: String?, input: Data? = nil) async -> String? {
        if let host { return await ProjectSource.ssh(host, script, input: input) }
        guard let tmux = LocalTmuxPlaces.executable() else { return nil }
        let path = (tmux as NSString).deletingLastPathComponent + ":/usr/bin:/bin"
        return await ProjectSource.run("/usr/bin/env", ["PATH=\(path)", "/bin/sh", "-c", script], input: input)
    }
}
