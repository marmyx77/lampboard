import AppKit
import LampBoardCore

/// What waits for you, as the panel holds it: the cards, which one is selected,
/// when each was first shown, and the keys while the panel has them (D74).
///
/// Since 1.1 the cards are not drawn above the rows (U2): a held ask is drawn
/// under its own row, J and K move a highlight down the rows that wait, and the
/// bar says how many. The model is the same; only where it shows changed.
///
/// Every decision is `WaitingQueue`'s; this keeps its state between refreshes,
/// redraws when a card arms, and turns keys into the panel's own actions.
@MainActor
final class WaitingQueueModel: ObservableObject {

    @Published private(set) var cards: [WaitingCard] = []
    @Published private(set) var cursor = WaitingQueue.Cursor()
    /// Asks answered somewhere else, shown dimmed for a moment so a card that
    /// vanishes under the pointer says why.
    @Published private(set) var resolved: [WaitingCard] = []
    /// Bumped when a card arms, so the view redraws it ready.
    @Published private(set) var armTick = 0
    /// Whether the panel holds the keyboard: only then is a card shown as
    /// selected, since only then does a key act on it.
    @Published private(set) var keyboardActive = false

    /// Opens a session, as a click on its row does.
    var onOpen: (String) -> Void = { _ in }
    var onMarkRead: ([String]) -> Void = { _ in }
    /// Allow or Deny for an ask the panel holds.
    /// `false` when the ask was gone already: said with a beep, not in silence.
    var onAnswer: (String, String, PermissionGate.Verdict) -> Bool = { _, _, _ in false }
    /// One of a held question's options (D86); `false` when it was gone already.
    var onChoose: (String, String, Int) -> Bool = { _, _, _ in false }
    /// The number of lines drawn changed: the panel has to be remeasured.
    var onLayoutChange: () -> Void = {}
    /// Whether the panel holds the keyboard now. Keys are only ever taken then.
    var holdsKeyboard: () -> Bool = { false }

    static let resolvedShownFor: TimeInterval = 1.2

    private var arming = WaitingQueue.Arming()
    /// Whether J or K moved the selection since the panel took the keyboard.
    /// Until they do, the selection is the most urgent card, wherever newer
    /// ones land; after, it stays on the card the user chose.
    private var moved = false
    private var actedOn: Set<String> = []
    private var armTimer: Timer?
    private var resolvedTimer: Timer?
    private var monitor: Any?

    /// The asks the panel holds, by session, each drawn under its row (U2).
    var held: [String: WaitingCard] { WaitingQueue.held(in: cards) }
    /// A held ask answered somewhere else, under its row for a moment.
    var resolvedHeld: [String: WaitingCard] {
        WaitingQueue.held(in: resolved).filter { held[$0.key] == nil }
    }
    /// The sessions with something drawn under their row: what the panel's
    /// height has to make room for.
    var inlineSessions: Set<String> { Set(held.keys).union(resolvedHeld.keys) }
    /// The bar's count.
    var countLine: String? { WaitingQueue.countLine(cards) }

    /// The sessions of the card J and K are on, while the panel has the keys.
    var selectedSessions: Set<String> {
        guard keyboardActive, cards.indices.contains(cursor.selected) else { return [] }
        return Set(cards[cursor.selected].sessionIds)
    }

    func isArmed(_ card: WaitingCard) -> Bool { arming.isArmed(card, now: Date()) }
    func isSelected(_ card: WaitingCard) -> Bool {
        keyboardActive && cards.indices.contains(cursor.selected) && cards[cursor.selected].id == card.id
    }

    /// The panel took or gave up the keyboard. Taking it starts from the top:
    /// the most urgent card, whatever was selected the last time.
    func keyboard(active: Bool) {
        if active { cursor = WaitingQueue.Cursor() }
        moved = false
        keyboardActive = active
    }

    func refresh(sessions: [SessionState], suggestions: [LampMasterShown], asks: [PermissionGate.Request] = [],
                 returned: Set<String> = [], now: Date = Date()) {
        let next = WaitingQueue.cards(sessions: sessions, suggestions: suggestions, asks: asks, now: now)
        arming.update(next, now: now)
        guard next != cards else { return }
        let before = inlineSessions
        let gone = WaitingQueue.resolvedElsewhere(before: cards, after: next, actedOn: actedOn, returned: returned)
        var followed = moved ? cursor : WaitingQueue.Cursor()
        if moved { followed.follow(from: cards, to: next) }
        cursor = followed
        actedOn = actedOn.intersection(next.map(\.id))
        cards = next
        if !gone.isEmpty { show(resolved: gone) }
        scheduleArming(now: now)
        if before != inlineSessions { onLayoutChange() }
    }

    /// A click on a card: what `O` does, once the card is armed.
    func click(_ card: WaitingCard) {
        guard isArmed(card), let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cursor = WaitingQueue.Cursor(selected: index)
        perform(cursor.selected, .open)
    }

    /// A click on a held permission's Allow or Deny: what `A` and `D` do, once
    /// the card is armed.
    func answer(_ card: WaitingCard, _ verdict: PermissionGate.Verdict) {
        guard isArmed(card), let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cursor = WaitingQueue.Cursor(selected: index)
        perform(cursor.selected, verdict == .allow ? .allow : .deny)
    }

    /// A click on one of a held question's options: what its digit does.
    func choose(_ card: WaitingCard, _ index: Int) {
        guard isArmed(card), let position = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cursor = WaitingQueue.Cursor(selected: position)
        perform(cursor.selected, .option(index + 1))
    }

    // MARK: - Keys

    /// Listens for keys while the panel holds the keyboard and the queue has
    /// something. A key it does not use goes on to the panel untouched.
    func startListening() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let key = Self.key(for: event), self.holdsKeyboard(), !self.cards.isEmpty else { return event }
            return self.press(key) ? nil : event
        }
    }

    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// `true` when the key was the queue's to take.
    @discardableResult
    func press(_ key: WaitingQueue.Key) -> Bool {
        if key == .next || key == .previous {
            var stepped = cursor
            let action = stepped.press(key, cards: cards)
            cursor = stepped
            moved = true
            return action != .unavailable
        }
        guard cards.indices.contains(cursor.selected), isArmed(cards[cursor.selected]) else { return true }
        return perform(cursor.selected, key)
    }

    @discardableResult
    private func perform(_ index: Int, _ key: WaitingQueue.Key) -> Bool {
        var step = cursor
        switch step.press(key, cards: cards) {
        case .open(let sessionId):
            actedOn.insert(cards[index].id)
            onOpen(sessionId)
        case .markRead(let ids):
            actedOn.insert(cards[index].id)
            onMarkRead(ids)
        case .answer(let session, let call, let verdict):
            actedOn.insert(cards[index].id)
            if !onAnswer(session, call, verdict) { NSSound.beep() }
        case .choose(let session, let call, let option):
            actedOn.insert(cards[index].id)
            if !onChoose(session, call, option) { NSSound.beep() }
        case .unavailable:
            // Said, not swallowed in silence: the key is right, the hand is not
            // there yet (D73).
            NSSound.beep()
        case .none, .moved:
            break
        }
        cursor = step
        return true
    }

    private static func key(for event: NSEvent) -> WaitingQueue.Key? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1 else { return nil }
        switch character {
        case "j": return .next
        case "k": return .previous
        case "o": return .open
        case "e": return .markRead
        case "a": return .allow
        case "s": return .always
        case "d": return .deny
        case "r": return .reply
        default:
            guard let digit = Int(character), (1...9).contains(digit) else { return nil }
            return .option(digit)
        }
    }

    // MARK: - Timing

    private func show(resolved gone: [WaitingCard]) {
        resolved = gone
        // One timer for the latest: an earlier one would clear these too soon.
        resolvedTimer?.invalidate()
        resolvedTimer = Timer.scheduledTimer(withTimeInterval: Self.resolvedShownFor, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resolved = []
                self.onLayoutChange()
            }
        }
    }

    /// A redraw each time a card arms, the earliest first: until then it looks
    /// unready, and a card that looks ready must be, and one that is should.
    private func scheduleArming(now: Date) {
        armTimer?.invalidate()
        guard let next = arming.nextArming(after: now) else { return }
        armTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armTick += 1
                self.scheduleArming(now: Date())
            }
        }
    }
}
