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
        case settings, gettingStarted, tour, checkForUpdates, legend, week

        public var title: String {
            switch self {
            case .settings: return "Settings"
            case .gettingStarted: return "Getting started"
            case .tour: return "Take the tour"
            case .checkForUpdates: return "Check for updates"
            case .legend: return "What the colours mean"
            case .week: return "This week"
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
            case .week: return ["week", "weekly", "summary", "recap"]
            }
        }
    }

    public struct Result: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case session, action, ask, send, askSession, conversation, handoff }
        public let id: String
        public let kind: Kind
        public let title: String
        public let detail: String
        public let sessionId: String?
        public let action: Action?
        public let status: SessionStatus?
        /// The session a handoff goes to (5.4).
        public var targetId: String? = nil
    }

    /// A conversation the search index found (0.7): which session, what it is
    /// called, where it ran, and the words around the match.
    public struct Found: Sendable, Equatable {
        public let sessionId: String
        public let title: String
        public let cwd: String?
        public let snippet: String

        public init(sessionId: String, title: String, cwd: String?, snippet: String) {
            self.sessionId = sessionId
            self.title = title
            self.cwd = cwd
            self.snippet = snippet
        }
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
                               sendingEnabled: Bool = false, askable: Set<String> = [], found: [Found] = []) -> [Result] {
        switch query {
        case .empty:
            return Array(rows.filter { $0.status.clearsOnFocus }
                .sorted { ($0.status.urgencyRank, $0.displayName) < ($1.status.urgencyRank, $1.displayName) }
                .map { session($0, now: now) }.prefix(shownAtOnce))
        case .text(let text):
            let words = text.lowercased()
            let live = sessions(matching: words, rows: rows, now: now, namesOnly: false)
            // What was said, after what is open: a conversation already a row is that row.
            let open = Set(rows.flatMap { $0.sessions.map(\.id) })
            let said = found.filter { !open.contains($0.sessionId) }.map { hit in
                Result(id: "found:" + hit.sessionId, kind: .conversation, title: RowActivity.flat(hit.title),
                       detail: RowActivity.flat(hit.snippet), sessionId: hit.sessionId, action: nil, status: nil)
            }
            return Array((live + actions(matching: words) + said).prefix(shownAtOnce))
        case .mention(let name, let message):
            let found = Array(sessions(matching: name.lowercased(), rows: rows, now: now, namesOnly: true).prefix(shownAtOnce))
            guard !message.isEmpty else { return found }
            // A session on another machine, by row id, with the machine's name.
            let remote = Dictionary(rows.compactMap { row in row.workspace.host.map { ("session:" + row.id, $0) } },
                                    uniquingKeysWith: { first, _ in first })
            if message.hasPrefix("?") {
                return asks(found, question: String(message.dropFirst()).trimmed, remote: remote,
                            sendingEnabled: sendingEnabled, askable: askable)
            }
            // One line, like a title: what is about to be said is read before it is.
            let said = RowActivity.flat(message)
            return found.map { session in
                // A session on another machine has its box there, reached over
                // ssh (B3): said, so a message is not taken to stay on this Mac.
                let host = remote[session.id]
                let detail = !sendingEnabled ? sendingOff
                    : host.map { "into its conversation on \($0), as you" } ?? "into its conversation, as you"
                return Result(id: "send:" + session.id, kind: .send, title: "Send to \(session.title): \(said)",
                              detail: detail, sessionId: session.sessionId, action: nil, status: session.status)
            }
        case .command(let name, let argument):
            guard !name.isEmpty, Handoff.command.hasPrefix(name) else { return actions(matching: name) }
            let handoff = handoffs(argument, rows: rows, now: now, sendingEnabled: sendingEnabled, askable: askable)
            // Its hint never above an action a short prefix also names (`/ho`, hooks).
            return name == Handoff.command || !argument.isEmpty ? handoff + actions(matching: name) : actions(matching: name) + handoff
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
    private static func asks(_ found: [Result], question: String, remote: [String: String],
                             sendingEnabled: Bool, askable: Set<String>) -> [Result] {
        guard !question.isEmpty else { return found }
        let asked = RowActivity.flat(question)
        return found.map { session in
            let can = session.sessionId.map(askable.contains) == true
            let place = remote[session.id].map { " on \($0)" } ?? ""
            let detail = !can ? askNeedsMod
                : (sendingEnabled ? "answered from its conversation\(place), with no turn" : sendingOff)
            return Result(id: "ask:" + session.id, kind: .askSession,
                          title: "Ask \(session.title) without disturbing it: \(asked)", detail: detail,
                          sessionId: can ? session.sessionId : nil, action: nil, status: session.status)
        }
    }

    /// `/handoff @from @to` (5.4): the first session, asked without a turn, writes
    /// what the second needs. Half typed, or naming no two sessions, a hint.
    private static func handoffs(_ argument: String, rows: [ColumnRow], now: Date,
                                 sendingEnabled: Bool, askable: Set<String>) -> [Result] {
        let names = argument.split(whereSeparator: \.isWhitespace).map { String($0.drop { $0 == "@" }).lowercased() }
        func best(_ name: String) -> Result? { sessions(matching: name, rows: rows, now: now, namesOnly: true).first }
        func hint(_ detail: String) -> [Result] {
            [Result(id: "handoff", kind: .handoff, title: "Hand a session over: /handoff @from @to",
                    detail: detail, sessionId: nil, action: nil, status: nil)]
        }
        guard names.count >= 2, let from = best(names[0]), let to = best(names[1]) else {
            return hint("the first writes what the second needs; you send it")
        }
        guard from.sessionId != to.sessionId else { return hint("two different sessions: one hands over to another") }
        let host = rows.first { "session:" + $0.id == to.id }?.workspace.host
        let can = from.sessionId.map(askable.contains) == true
        let detail = !can ? askNeedsMod : !sendingEnabled ? sendingOff
            : "\(from.title) writes it from its conversation, with no turn; "
                + (host.map { "copied for \(to.title) on \($0)" } ?? "you send it from \(to.title)'s Plancia")
        return [Result(id: "handoff:\(from.id):\(to.id)", kind: .handoff, title: "Hand \(from.title) over to \(to.title)",
                       detail: detail, sessionId: can && sendingEnabled ? from.sessionId : nil, action: nil,
                       status: from.status, targetId: to.sessionId)]
    }

    static let sendingOff = "Turn on \"Let the panel answer your sessions\" in the panel menu first"

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
