import Foundation

/// The bar at the top of the wide panel (UX §2, D77): one box that finds a
/// session, runs an action, or puts a question to LampMaster. Pure: the panel
/// draws the results and does what the chosen one says.
public enum CommandBar {

    public enum Query: Sendable, Equatable {
        case empty
        case text(String)
        /// `@name message`: a session, and what to say to it (D73, D81); a name
        /// alone finds it.
        case mention(name: String, message: String)
        /// `?question`: to LampMaster.
        case ask(String)
        /// `/name argument`: an action by its name.
        case command(name: String, argument: String)
    }

    public enum Action: String, Sendable, CaseIterable {
        case settings, gettingStarted, tour, checkForUpdates, legend

        public var title: String {
            switch self {
            case .settings: return "Settings"
            case .gettingStarted: return "Getting started"
            case .tour: return "Take the tour"
            case .checkForUpdates: return "Check for updates"
            case .legend: return "What the colours mean"
            }
        }

        /// The words an action answers to, besides its title.
        var words: [String] {
            switch self {
            case .settings: return ["settings", "preferences", "options"]
            case .gettingStarted: return ["getting", "started", "setup", "hooks"]
            case .tour: return ["tour", "tutorial", "trial"]
            case .checkForUpdates: return ["update", "upgrade", "version"]
            case .legend: return ["legend", "colours", "colors", "help"]
            }
        }
    }

    public struct Result: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case session, action, ask, send, askSession }
        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String
        public let sessionId: String?
        public let action: Action?
        public let status: SessionStatus?
    }

    /// The most results a list shows: past eight, the bar has stopped narrowing.
    public static let shownAtOnce = 8

    public static func parse(_ raw: String) -> Query {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return .empty }
        let rest = String(text.dropFirst())
        let (head, tail) = split(rest)
        switch first {
        case "@": return .mention(name: head, message: tail)
        case "?": return .ask(rest.trimmingCharacters(in: .whitespaces))
        case "/": return .command(name: head.lowercased(), argument: tail)
        default: return .text(text)
        }
    }

    public static func results(for query: Query, rows: [ColumnRow], now: Date, lampMasterEnabled: Bool,
                               sendingEnabled: Bool = false, askable: Set<String> = []) -> [Result] {
        switch query {
        case .empty:
            return Array(rows.filter { $0.status.clearsOnFocus }
                .sorted { ($0.status.urgencyRank, $0.displayName) < ($1.status.urgencyRank, $1.displayName) }
                .map { session($0, now: now) }.prefix(shownAtOnce))
        case .text(let text):
            let words = text.lowercased()
            return Array((sessions(matching: words, rows: rows, now: now, namesOnly: false)
                + actions(matching: words)).prefix(shownAtOnce))
        case .mention(let name, let message):
            let found = Array(sessions(matching: name.lowercased(), rows: rows, now: now, namesOnly: true).prefix(shownAtOnce))
            guard !message.isEmpty else { return found }
            let remote = Set(rows.filter(\.workspace.isRemote).map { "session:" + $0.id })
            if message.hasPrefix("?") {
                return asks(found, question: String(message.dropFirst()).trimmed, remote: remote,
                            sendingEnabled: sendingEnabled, askable: askable)
            }
            // One line, like a title: what is about to be said is read before it is.
            let said = RowActivity.flat(message)
            return found.map { session in
                // A session on another Mac has its box there: said, and nothing
                // to send to (no session id), rather than a send that goes nowhere.
                let away = remote.contains(session.id)
                return Result(id: "send:" + session.id, kind: .send, title: "Send to \(session.title): \(said)",
                              detail: away ? sendingRemote : (sendingEnabled ? "into its conversation, as you" : sendingOff),
                              sessionId: away ? nil : session.sessionId, action: nil, status: session.status)
            }
        case .command(let name, _):
            return actions(matching: name)
        case .ask(let question):
            guard !question.isEmpty else { return [] }
            return [Result(id: "ask", kind: .ask, title: "Ask LampMaster: " + question,
                           detail: lampMasterEnabled ? "LampMaster reads your sessions and answers here"
                                                     : "LampMaster is switched off in Settings",
                           sessionId: nil, action: nil, status: nil)]
        }
    }

    static let askNeedsMod = "Its session needs the LampBoard mod 1.5.0: restart it after the update"

    /// `@name ?question`: each session found, asked without disturbing it
    /// (D82) — only one whose mod said it can answer, on this Mac.
    private static func asks(_ found: [Result], question: String, remote: Set<String>,
                             sendingEnabled: Bool, askable: Set<String>) -> [Result] {
        guard !question.isEmpty else { return found }
        let asked = RowActivity.flat(question)
        return found.map { session in
            let away = remote.contains(session.id)
            let can = !away && session.sessionId.map(askable.contains) == true
            let detail = away ? sendingRemote : !can ? askNeedsMod
                : (sendingEnabled ? "answered from its conversation, with no turn" : sendingOff)
            return Result(id: "ask:" + session.id, kind: .askSession,
                          title: "Ask \(session.title) without disturbing it: \(asked)", detail: detail,
                          sessionId: can ? session.sessionId : nil, action: nil, status: session.status)
        }
    }

    static let sendingOff = "Turn on \"Let the panel answer your sessions\" in the panel menu first"
    static let sendingRemote = "On another Mac: the panel cannot write there yet"

    /// The selection after a move, kept inside the list.
    public static func move(_ index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + step, 0), count - 1)
    }

    // MARK: - Internals

    private static func split(_ text: String) -> (String, String) {
        guard let space = text.firstIndex(where: \.isWhitespace) else { return (text, "") }
        return (String(text[..<space]), text[space...].trimmingCharacters(in: .whitespaces))
    }

    private static func session(_ row: ColumnRow, now: Date) -> Result {
        // A title can come from a transcript: one line, no control or bidi
        // character, as the row's own second line is.
        Result(id: "session:" + row.id, kind: .session, title: RowActivity.flat(row.displayName),
               detail: RowActivity.line(for: row, now: now), sessionId: row.primary.id, action: nil, status: row.status)
    }

    /// Names first — exact, from the start, from a word, anywhere — and then
    /// what a session says or is titled. Ties go to the more urgent.
    private static func sessions(matching query: String, rows: [ColumnRow], now: Date, namesOnly: Bool) -> [Result] {
        guard !query.isEmpty else { return [] }
        let scored: [(Int, ColumnRow)] = rows.compactMap { row in
            let name = row.displayName.lowercased()
            let score: Int
            if name == query { score = 100 }
            else if name.hasPrefix(query) { score = 80 }
            else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) { score = 60 }
            else if name.contains(query) { score = 40 }
            else if !namesOnly, ([row.primary.title ?? "", RowActivity.line(for: row, now: now)]
                .contains { $0.lowercased().contains(query) }) { score = 20 }
            else { return nil }
            return (score, row)
        }
        return scored
            .sorted { ($1.0, $0.1.status.urgencyRank, $0.1.displayName) < ($0.0, $1.1.status.urgencyRank, $1.1.displayName) }
            .map { session($0.1, now: now) }
    }

    private static func actions(matching query: String) -> [Result] {
        let query = query.lowercased()
        guard !query.isEmpty else { return [] }
        return Action.allCases.filter { action in
            let words = action.words + action.title.lowercased().split(separator: " ").map(String.init)
            return words.contains { $0.hasPrefix(query) } || action.title.lowercased().hasPrefix(query)
        }.map { Result(id: "action:" + $0.rawValue, kind: .action, title: $0.title, detail: "", sessionId: nil, action: $0, status: nil) }
    }
}
