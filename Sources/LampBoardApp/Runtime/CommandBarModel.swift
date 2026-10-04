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
    @Published private(set) var asking = false
    /// Whether the field is open. At rest the bar is a button, not a field: a
    /// field takes the keyboard by itself the moment the panel becomes key, and
    /// then the queue's keys would type into it. Opened by a click or `⌘K`;
    /// while open, the queue's keys stand down.
    @Published private(set) var isEditing = false
    /// Bumped on `⌘K` while open: the field takes the keyboard back.
    @Published private(set) var focusTick = 0

    var onOpenSession: (String) -> Void = { _ in }
    var onAction: (CommandBar.Action) -> Void = { _ in }
    /// Asks LampMaster, the way a session does through the MCP tool.
    var onAsk: (String) async -> String = { _ in "" }
    var onLayoutChange: () -> Void = {}

    private var rows: [ColumnRow] = []
    private var lampMasterEnabled = false
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

    func update(rows: [ColumnRow], lampMasterEnabled: Bool) {
        self.rows = rows
        self.lampMasterEnabled = lampMasterEnabled
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
        switch result.kind {
        case .session:
            if let id = result.sessionId { onOpenSession(id) }
            clear()
        case .action:
            if let action = result.action { onAction(action) }
            clear()
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
        selected = 0
        refresh()
        onLayoutChange()
    }

    private func cancelQuestion() {
        question?.cancel()
        question = nil
        asking = false
    }

    private func refresh() {
        let next = CommandBar.results(for: CommandBar.parse(text), rows: rows, now: Date(), lampMasterEnabled: lampMasterEnabled)
        guard next != results else { return }
        results = next
        selected = CommandBar.move(selected, by: 0, count: shownResults.count)
        onLayoutChange()
    }
}
