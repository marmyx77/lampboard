import Foundation
import LampBoardCore

/// The bar at the top of the wide panel, as the panel holds it (D77): what is
/// typed, what it finds, which result is selected, LampMaster's answer.
///
/// Every decision is `CommandBar`'s; this keeps the text and the answer, and
/// hands the chosen result to the panel. The panel is asked to remeasure on
/// every change that can move the bar's height, without comparing first: its
/// own resize returns when nothing changed, and a comparison here once read the
/// count after the text had already changed and left a gap where results were.
@MainActor
final class CommandBarModel: ObservableObject {

    @Published var text = "" { didSet { if text != oldValue { textChanged() } } }
    @Published private(set) var results: [CommandBar.Result] = []
    @Published private(set) var selected = 0
    @Published private(set) var answer: String?
    /// The week's figures, drawn as tiles above its projects (R5); empty otherwise.
    @Published private(set) var weekTiles: [WeekSummary.Tile] = []
    @Published private(set) var asking = false
    /// Whether the field is open. At rest the bar is a button, not a field: a
    /// field takes the keyboard by itself the moment the panel becomes key, and
    /// then the queue's keys would type into it. Opened by a click or `⌘K`;
    /// while open, the queue's keys stand down.
    @Published private(set) var isEditing = false
    /// Bumped on `⌘K` while open: the field takes the keyboard back.
    @Published private(set) var focusTick = 0

    var onOpenSession: (String) -> Void = { _ in }
    /// Any result chosen: what the tour's ⌘K step waits for.
    var onChose: () -> Void = {}
    var onAction: (CommandBar.Action) -> Void = { _ in }
    /// Asks LampMaster, the way a session does through the MCP tool.
    var onAsk: (String) async -> String = { _ in "" }
    /// `@name message`: the message to that session. `nil` when it went into
    /// a Plancia that shows it; otherwise what to say in the bar, which keeps
    /// the text — a refusal, or where a session on another machine took it.
    var onSend: @MainActor (String, String) async -> String? = { _, _ in "Sending is not available." }
    /// `@name ?question`: the session's fork answers it, no turn (D82).
    var onAskSession: @MainActor (String, String) async -> String = { _, _ in "" }
    /// The search index's answer for the typed words (0.7), off the main actor.
    var onSearch: @Sendable (String) -> [CommandBar.Found] = { _ in [] }
    /// A conversation found: what to say in the bar about reaching it.
    var onConversation: @MainActor (String, String?) -> String = { _, _ in "" }
    /// `/handoff @from @to` (5.4): what the bar says, or `nil` when the handoff
    /// waits in the second session's Plancia.
    var onHandoff: @MainActor (String, String) async -> String? = { _, _ in "Handing over is not available." }
    /// The week in a paragraph, from the search index, off the main actor.
    /// The week counted, or `nil` when the search index cannot be read.
    var onWeek: @Sendable () -> WeekSummary.Summary? = { nil }
    var onLayoutChange: () -> Void = {}

    private var rows: [ColumnRow] = []
    private var lampMasterEnabled = false
    private var sendingEnabled = false
    private var askable: Set<String> = []
    private var found: [CommandBar.Found] = []
    private var searching: Task<Void, Never>?
    private var question: Task<Void, Never>?

    /// Results only while something is typed. Empty, the queue below already
    /// says what needs you.
    var shownResults: [CommandBar.Result] { isEditing && !text.isEmpty ? results : [] }
    /// The answer only in an open bar: one that arrives after it closed is dropped.
    var shownAnswer: String? { isEditing ? answer : nil }

    func focus() {
        if isEditing { focusTick += 1 } else { isEditing = true }
        onLayoutChange()
    }

    func update(rows: [ColumnRow], lampMasterEnabled: Bool, sendingEnabled: Bool, askable: Set<String> = []) {
        self.rows = rows
        self.askable = askable
        self.lampMasterEnabled = lampMasterEnabled
        self.sendingEnabled = sendingEnabled
        refresh()
    }

    func move(_ step: Int) {
        selected = CommandBar.move(selected, by: step, count: shownResults.count)
    }

    /// `⏎`: the selected result.
    func submit() {
        guard shownResults.indices.contains(selected) else { return }
        choose(shownResults[selected])
    }

    func choose(_ result: CommandBar.Result) {
        onChose()
        switch result.kind {
        case .session:
            if let id = result.sessionId { onOpenSession(id) }
            clear()
        case .handoff:
            // A hint chooses nothing; switched off, the result says how to switch it on.
            guard sendingEnabled, let from = result.sessionId, let to = result.targetId, !asking else { return }
            let typed = text
            asking = true
            answer = "Writing the handoff, without a turn…"
            onLayoutChange()
            question = Task { [weak self] in
                guard let self else { return }
                let said = await self.onHandoff(from, to)
                // Asked, so it lands in the Plancia whatever the bar does now.
                guard !Task.isCancelled, self.isEditing, self.text == typed else { return }
                self.asking = false
                guard let said else { return self.clear() }
                self.answer = said
                self.onLayoutChange()
            }
        case .action where result.action == .week:
            // Said in the bar, like an answer: read off the main actor, once at a time.
            guard !asking else { return }
            cancelQuestion()
            answer = "Reading the week…"
            onLayoutChange()
            let typed = text, week = onWeek
            question = Task { [weak self] in
                let summary = await Task.detached { week() }.value
                guard let self, !Task.isCancelled, self.isEditing, self.text == typed else { return }
                guard let summary else {
                    self.answer = "The search index is not available."
                    return self.onLayoutChange()
                }
                // The tiles say the paragraph's first line; the projects follow it.
                self.weekTiles = WeekSummary.tiles(summary)
                let lines = WeekSummary.text(summary).split(separator: "\n", omittingEmptySubsequences: false)
                self.answer = self.weekTiles.isEmpty ? lines.joined(separator: "\n")
                    : lines.dropFirst().joined(separator: "\n")
                self.onLayoutChange()
            }
        case .action:
            if let action = result.action { onAction(action) }
            clear()
        case .send:
            // Switched off, the result says how to switch it on, and stays.
            guard sendingEnabled, let id = result.sessionId, !asking,
                  case .mention(_, let message) = CommandBar.parse(text), !message.isEmpty else { return }
            let typed = text
            asking = true
            answer = "Sending…"
            onLayoutChange()
            question = Task { [weak self] in
                guard let self else { return }
                let said = await self.onSend(id, message)
                // Already on its way, whatever the bar does now: said in the log
                // when the bar no longer shows it.
                guard !Task.isCancelled, self.isEditing, self.text == typed else {
                    return Diagnostics.log("bar: a send finished after the bar moved on: \(said ?? "sent")")
                }
                self.asking = false
                guard let said else { return self.clear() }
                self.answer = said
                self.onLayoutChange()
            }
        case .conversation:
            guard let id = result.sessionId else { return }
            answer = onConversation(id, found.first { $0.sessionId == id }?.cwd)
            onLayoutChange()
        case .askSession:
            guard sendingEnabled, let id = result.sessionId, !asking,
                  case .mention(_, let message) = CommandBar.parse(text), message.hasPrefix("?") else { return }
            let asked = String(message.dropFirst()).trimmingCharacters(in: .whitespaces)
            let typed = text
            asking = true
            answer = "Asking it, without a turn…"
            onLayoutChange()
            question = Task { [weak self] in
                guard let self else { return }
                let reply = await self.onAskSession(id, asked)
                // Dropped if the bar closed or the question changed meanwhile.
                guard !Task.isCancelled, self.isEditing, self.text == typed else { return }
                self.answer = reply
                self.asking = false
                self.onLayoutChange()
            }
        case .ask:
            guard lampMasterEnabled, case .ask(let asked) = CommandBar.parse(text), !asking else { return }
            asking = true
            answer = "LampMaster is reading your sessions…"
            onLayoutChange()
            question = Task { [weak self] in
                guard let self else { return }
                let reply = await self.onAsk(asked)
                // Dropped if the bar closed or the question changed meanwhile:
                // an answer under a different question reads as its answer.
                guard !Task.isCancelled, self.isEditing, CommandBar.parse(self.text) == .ask(asked) else { return }
                self.answer = reply
                self.asking = false
                self.onLayoutChange()
            }
        }
    }

    /// `Esc`, or a result chosen: the bar closes, empty.
    func clear() {
        cancelQuestion()
        answer = nil
        weekTiles = []
        text = ""
        selected = 0
        isEditing = false
        onLayoutChange()
    }

    /// The field lost the keyboard: an empty one closes, one with text stays.
    func blurred() {
        if text.isEmpty, answer == nil, isEditing { clear() }
    }

    private func textChanged() {
        cancelQuestion()
        answer = nil
        weekTiles = []
        selected = 0
        found = []
        refresh()
        onLayoutChange()
        search()
    }

    /// The index, a moment after the typing stops, off the main actor; an
    /// answer for words no longer typed is dropped.
    private func search() {
        searching?.cancel()
        guard case .text(let words) = CommandBar.parse(text), words.count >= 3 else { return }
        let lookup = onSearch
        searching = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) { lookup(words) }.value
            guard let self, !Task.isCancelled, CommandBar.parse(self.text) == .text(words) else { return }
            self.found = hits
            self.refresh()
        }
    }

    private func cancelQuestion() {
        question?.cancel()
        question = nil
        asking = false
    }

    private func refresh() {
        let next = CommandBar.results(for: CommandBar.parse(text), rows: rows, now: Date(),
                                      lampMasterEnabled: lampMasterEnabled, sendingEnabled: sendingEnabled, askable: askable,
                                      found: found)
        guard next != results else { return }
        // The selection stays on the result it was on, not on its place: a
        // list reordered by a status change must not turn `⏎` into a send to
        // another session (a review finding).
        let was = shownResults.indices.contains(selected) ? shownResults[selected].id : nil
        results = next
        if let was, let index = shownResults.firstIndex(where: { $0.id == was }) { selected = index }
        selected = CommandBar.move(selected, by: 0, count: shownResults.count)
        onLayoutChange()
    }
}
