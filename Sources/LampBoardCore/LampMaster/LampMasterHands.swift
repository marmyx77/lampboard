import Foundation

/// LampMaster's hands (hub-terminale R10–R11): what LampMaster, itself a Claude
/// Code session LampBoard hosts, may do across the other sessions. The tools come
/// from the `lampboard` MCP server, which only LampMaster's own folder loads, and
/// the panel answers them only for the session it started as LampMaster.
///
/// Reading is free. Every action — writing into a session, stopping one, starting
/// one, opening one in the Hub — is a tool Claude Code asks the person about
/// before it runs: the click stays the person's.
public enum LampMasterHands {

    public static let serverName = "lampboard"

    public enum Tool: String, CaseIterable, Sendable {
        case sessions
        case readSession = "read_session"
        case sendToSession = "send_to_session"
        case stopSession = "stop_session"
        case startSession = "start_session"
        case openInHub = "open_in_hub"

        /// Tools that change something: never allowed ahead in LampMaster's
        /// settings, so Claude Code asks every time.
        public var acts: Bool { self != .sessions && self != .readSession }

        public var description: String {
            switch self {
            case .sessions:
                return "Every Claude Code session of this developer, on this Mac and on other machines: its id, name, "
                    + "project, machine, where it runs (tmux, background, VS Code, the Claude app), its state, how long "
                    + "since it last moved, and whether LampBoard can write into it."
            case .readSession:
                return "The last messages of one session, by its id or the start of it: what was asked, what it answered."
            case .sendToSession:
                return "Writes a message into one session and sends it, as the person would type it. Only a session "
                    + "in tmux, at rest, with nothing typed in its prompt; it arrives marked as coming from LampMaster. "
                    + "Use it only when the person asked for it."
            case .stopSession:
                return "Stops the turn a session is running (Esc in its terminal). Only a session in tmux that is working."
            case .startSession:
                return "Starts a session in a project folder, on this Mac or on a machine of Settings › Other Macs, "
                    + "in tmux; or takes up a past conversation by its id. It opens in LampBoard's Hub."
            case .openInHub:
                return "Shows a session in LampBoard's Hub, in its own terminal, for the person to look at."
            }
        }

        var inputSchema: [String: Any] {
            let text: [String: Any] = ["type": "string", "maxLength": LampMasterHands.maxText]
            let id: [String: Any] = ["type": "string", "maxLength": 64]
            func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
                ["type": "object", "properties": properties, "required": required]
            }
            switch self {
            case .sessions: return object([:], [])
            case .readSession: return object(["session": id, "messages": ["type": "integer", "minimum": 1, "maximum": 20]], ["session"])
            case .sendToSession: return object(["session": id, "text": text], ["session", "text"])
            case .stopSession, .openInHub: return object(["session": id], ["session"])
            case .startSession:
                return object(["folder": ["type": "string", "maxLength": 1024], "host": id, "resume": id], ["folder"])
            }
        }
    }

    /// The most LampMaster writes into a session at once.
    public static let maxText = 4_000

    /// The answer to one line from Claude Code, or `nil` when none is due; the
    /// protocol is `LampMasterMCP`'s.
    public static func respond(
        to line: String, version: String, call: (Tool, [String: Any]) -> (text: String, isError: Bool)
    ) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return LampMasterMCP.encode(id: NSNull(), error: (-32700, "Parse error")) }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String ?? "" {
        case "initialize":
            return LampMasterMCP.encode(id: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-11-25",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": version],
                "instructions": "LampBoard's hands across this developer's sessions. Read freely; act only when asked.",
            ])
        case "ping":
            return LampMasterMCP.encode(id: id, result: [:])
        case "tools/list":
            return LampMasterMCP.encode(id: id, result: ["tools": Tool.allCases.map {
                ["name": $0.rawValue, "description": $0.description, "inputSchema": $0.inputSchema]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Tool(rawValue: name) else {
                return LampMasterMCP.encode(id: id, error: (-32602, "Unknown tool"))
            }
            let outcome = call(tool, params["arguments"] as? [String: Any] ?? [:])
            let text = tool.acts ? outcome.text : LampMasterMCP.dataNotice + "\n" + outcome.text
            return LampMasterMCP.encode(id: id, result: ["content": [["type": "text", "text": text]], "isError": outcome.isError])
        default:
            return LampMasterMCP.encode(id: id, error: (-32601, "Method not found"))
        }
    }

    // MARK: - Sessions

    /// Where a session runs, as far as writing into it goes.
    public enum Surface: String, Sendable {
        case tmux, background, vscode, app, other
    }

    /// What LampMaster is told of one session.
    public struct Facts: Equatable, Sendable {
        public let id: String
        public let name: String
        public let project: String
        public let host: String?
        public let surface: Surface
        public let status: SessionStatus
        public let minutes: Int
        public let isLampMaster: Bool

        public init(id: String, name: String, project: String, host: String?, surface: Surface,
                    status: SessionStatus, minutes: Int, isLampMaster: Bool = false) {
            self.id = id; self.name = name; self.project = project; self.host = host
            self.surface = surface; self.status = status; self.minutes = minutes; self.isLampMaster = isLampMaster
        }
    }

    /// The list, one session a line, LampMaster itself left out.
    public static func list(_ sessions: [Facts]) -> String {
        let others = sessions.filter { !$0.isLampMaster }
        guard !others.isEmpty else { return "No other session is running." }
        return others.map { s in
            let place = s.host ?? "this Mac"
            let writable = canSend(s, promptEmpty: true) == .send ? "writable" : "read only"
            return "\(s.id.prefix(8)) · \(s.name) · \(s.project) on \(place) · \(s.surface.rawValue) · \(s.status.rawValue) "
                + "\(s.minutes) min ago · \(writable)"
        }
        .joined(separator: "\n")
    }

    /// The session `query` names: a whole id, or the unique start of one.
    public static func find(_ query: String, in sessions: [Facts]) -> Facts? {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard wanted.count >= 4 else { return nil }
        let matches = sessions.filter { $0.id.lowercased().hasPrefix(wanted) }
        return matches.count == 1 ? matches[0] : nil
    }

    public enum Verdict: Equatable, Sendable {
        case send
        case refuse(String)
    }

    /// Whether LampMaster may write into `session` now. `promptEmpty` is what its
    /// screen says of its prompt, `nil` when it could not be read.
    public static func canSend(_ session: Facts, promptEmpty: Bool?) -> Verdict {
        if session.isLampMaster { return .refuse("That is LampMaster's own session.") }
        switch session.surface {
        case .tmux: break
        case .vscode:
            return .refuse("\(session.name) runs in VS Code's panel: LampBoard only reads it. Move it to LampBoard first.")
        case .app:
            return .refuse("\(session.name) runs in the Claude app: LampBoard only reads it.")
        case .background:
            return .refuse("\(session.name) runs in the background: open it in the Hub and write there.")
        case .other:
            return .refuse("LampBoard has no terminal into \(session.name).")
        }
        switch session.status {
        case .working, .waiting:
            return .refuse("\(session.name) is working. Wait for its turn to end, or stop it first.")
        case .awaiting:
            return .refuse("\(session.name) is asking the person something: it is theirs to answer, in the Hub.")
        default: break
        }
        guard promptEmpty == true else {
            return .refuse("Something is typed in \(session.name)'s prompt, or it could not be read: nothing is mixed into it.")
        }
        return .send
    }

    /// Whether LampMaster may stop `session`'s turn.
    public static func canStop(_ session: Facts) -> Verdict {
        if session.isLampMaster { return .refuse("That is LampMaster's own session.") }
        guard session.surface == .tmux else { return .refuse("LampBoard has no terminal into \(session.name) to press Esc in.") }
        guard session.status == .working || session.status == .waiting else { return .refuse("\(session.name) is not working.") }
        return .send
    }

    /// The last `messages` of a transcript's tail, the person's and the
    /// session's, each cut to a bound. The tail may begin inside a line: a line
    /// that does not read is left out.
    public static func digest(tail: String, messages: Int) -> String {
        let entries = tail.split(separator: "\n").flatMap { TranscriptDecoder.entries(fromLine: String($0)) }
            .filter { $0.kind == .human || $0.kind == .assistant }
        let last = entries.suffix(max(1, min(messages, 20)))
        guard !last.isEmpty else { return "Nothing said yet in this session." }
        return last.map { entry in
            let who = entry.kind == .human ? "person" : "session"
            let text = entry.text.count > 1_200 ? String(entry.text.prefix(1_200)) + " …" : entry.text
            return "[\(who)] \(text)"
        }
        .joined(separator: "\n\n")
    }

    /// The message as it arrives: marked as LampMaster's, without control or
    /// format characters, bounded.
    public static func framed(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || !(CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format)
        }))
        return "[From LampMaster, at the person's request] " + String(clean.prefix(maxText)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whether Claude Code's prompt holds anything the person typed, from tmux's
/// cursor: an empty prompt has the cursor right after `❯ `, even with the grey
/// suggestion Claude Code writes after it; typed text moves the cursor on, and a
/// second line moves it down. (A person who typed and then went back to the start
/// of the line reads as empty: LampMaster acts only when asked, and asks first.)
public enum PromptLine {

    public static func isEmpty(lines: [String], cursorX: Int, cursorY: Int) -> Bool {
        guard lines.indices.contains(cursorY) else { return false }
        let line = lines[cursorY]
        guard let mark = line.firstIndex(where: { $0 != " " }), line[mark] == "❯" || line[mark] == ">" else { return false }
        // One cell for each character before the mark, one for the mark, one for the space.
        return cursorX == line.distance(from: line.startIndex, to: mark) + 2
    }
}

/// The scripts LampMaster's hands run on tmux, here or over ssh: every target is
/// quoted, the text goes by standard input, never as an argument.
public enum HandsScript {

    /// The pane's cursor, then its screen.
    public static func look(target: String) -> String {
        let t = NewSession.shellQuoted(target)
        // `-u`: without a locale tmux writes `❯` and every other non-ASCII character as `_`.
        return "tmux -u display-message -p -t \(t) '#{cursor_x} #{cursor_y}' && tmux -u capture-pane -p -t \(t)"
    }

    /// The cursor and the screen, read back.
    public static func parseLook(_ output: String) -> (lines: [String], x: Int, y: Int)? {
        var lines = output.components(separatedBy: "\n")
        guard let first = lines.first else { return nil }
        let numbers = first.split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        lines.removeFirst()
        return (lines, numbers[0], numbers[1])
    }

    /// Standard input pasted into the pane as one paste (bracketed, so a line
    /// break does not send early), then Enter.
    public static func send(target: String) -> String {
        let t = NewSession.shellQuoted(target)
        return "tmux load-buffer -b lampmaster - && tmux paste-buffer -p -d -b lampmaster -t \(t) && sleep 0.3 && tmux send-keys -t \(t) Enter"
    }

    public static func stop(target: String) -> String {
        "tmux send-keys -t \(NewSession.shellQuoted(target)) Escape"
    }
}
