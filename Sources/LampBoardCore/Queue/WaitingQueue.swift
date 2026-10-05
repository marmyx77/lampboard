import Foundation

/// One thing in "Waiting for you": a session's ask, a stuck or failed turn,
/// answers to read, or LampMaster's suggestion (UX §3).
public struct WaitingCard: Sendable, Equatable, Identifiable {

    /// In the order the queue shows them: what stops work first, what can wait
    /// last. LampMaster is always last, because it is advice, never a block.
    /// The names are part of each card's id, so they are spelled out: a
    /// reordered list must not change what a card is called.
    public enum Kind: String, Sendable, Comparable, CaseIterable {
        case permission, question, stuck, failed, ready, readyGroup, lampMaster

        public static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// Stable while the card means the same thing: the selection follows it,
    /// and "resolved elsewhere" compares it.
    public let id: String
    public let kind: Kind
    public let sessionIds: [String]
    public let title: String
    /// What it asks or says, in one line.
    public let line: String
    /// When what the card says began: the age that orders it. Not when its
    /// buttons arm — that counts from when the queue first showed it
    /// (`Arming`), since a session can carry an old state into the queue.
    public let appearedAt: Date
    /// LampMaster's other open suggestions, behind this one («+2»).
    public let more: Int
    /// The call a permission waits on while the panel holds it (D80): only
    /// then can the card's Allow and Deny answer it.
    public var call: String? = nil
    /// A held question's options (D86): a digit chooses one.
    public var options: [String] = []
    /// What a permission would do (D87).
    public var impact: String? = nil
}

/// What waits for you, in order, and what a key does to it. Pure: the panel
/// draws it and does what the answer says.
public enum WaitingQueue {

    /// A card's buttons do nothing for this long after it appears: a permission
    /// that pops up under the pointer is never approved by the click that was
    /// meant for something else.
    public static let armDelay: TimeInterval = 0.6
    /// Ready answers stand one card each up to this many; more are one card.
    public static let readyStandAlone = 2

    public static func cards(sessions: [SessionState], suggestions: [LampMasterShown],
                             asks: [PermissionGate.Request] = [], now: Date) -> [WaitingCard] {
        var cards = asks.map { held($0, in: sessions) }
        var ready: [SessionState] = []
        for session in sessions {
            // The state the row shows, not the one beneath it: with a subagent
            // alive, a finished or failed parent is blue, and a queue calling it
            // green would be the lie D22 removed from the row.
            switch session.status {
            case .awaiting:
                let question = session.pendingAsk?.tool == "AskUserQuestion"
                var asked = card(session, question ? .question : .permission,
                                 line: session.pendingAsk?.sentence ?? SessionStatus.awaiting.label)
                asked.impact = session.pendingAsk.flatMap { PermissionImpact.of(tool: $0.tool, line: $0.detail ?? "") }
                cards.append(asked)
            case .failed:
                cards.append(card(session, .failed, line: session.failureReason?.detailedLabel ?? "the turn failed"))
            // A finished command asks nothing to be read: its row already says it.
            case .ready where session.harness != .command:
                ready.append(session)
            case .working:
                guard let tool = session.stuckTool(at: now) else { continue }
                let line = PendingAsk(tool: tool.tool, detail: tool.detail).sentence
                cards.append(card(session, .stuck, line: line, appearedAt: tool.since.addingTimeInterval(RunningTool.stuckAfter)))
            default:
                continue
            }
        }
        cards += readyCards(ready)
        if let shown = LampMasterLedger.open(suggestions).first {
            cards.append(WaitingCard(
                id: "lampmaster:\(shown.id)", kind: .lampMaster, sessionIds: shown.suggestion.sessions,
                title: LampMasterLine.title(shown.suggestion.kind), line: shown.suggestion.text,
                appearedAt: shown.at, more: LampMasterLedger.open(suggestions).count - 1))
        }
        return cards.sorted { ($0.kind, $0.appearedAt, $0.id) < ($1.kind, $1.appearedAt, $1.id) }
    }

    /// The most cards drawn at once: past four, a queue pushes the column it
    /// sits on off the screen, and the fifth thing is never what you do next.
    public static let shownAtOnce = 4

    /// Which cards are drawn: the first four, or four ending at the selected
    /// one once it is further down.
    public static func window(count: Int, selected: Int) -> Range<Int> {
        guard count > shownAtOnce else { return 0..<count }
        let end = min(max(selected + 1, shownAtOnce), count)
        return (end - shownAtOnce)..<end
    }

    public static func isArmed(appearedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(appearedAt) >= armDelay
    }

    /// When the queue first showed each card, as it is now: a card that comes
    /// back changed — a new ask in the same session, a new member in the
    /// group of answers — is shown anew and armed anew.
    public struct Arming: Sendable, Equatable {
        private var firstShown: [String: Date] = [:]

        public init() {}

        public mutating func update(_ cards: [WaitingCard], now: Date) {
            var next: [String: Date] = [:]
            for card in cards {
                let key = Self.key(card)
                next[key] = firstShown[key] ?? now
            }
            firstShown = next
        }

        /// When the next card still unarmed arms, so the panel redraws then and
        /// not only when the newest one does.
        public func nextArming(after now: Date) -> Date? {
            firstShown.values.map { $0.addingTimeInterval(WaitingQueue.armDelay) }.filter { $0 > now }.min()
        }

        public func isArmed(_ card: WaitingCard, now: Date) -> Bool {
            guard let shown = firstShown[Self.key(card)] else { return false }
            return WaitingQueue.isArmed(appearedAt: shown, now: now)
        }

        private static func key(_ card: WaitingCard) -> String {
            card.id + "|" + card.sessionIds.joined(separator: ",")
        }
    }

    /// Asks that left without the panel answering them: answered in the
    /// terminal, most likely. The panel says so for a second. Only asks: a
    /// stuck tool that ends, or an answer read by clicking its row, resolved
    /// nothing elsewhere.
    /// What a card gone elsewhere says for its moment: an ask the panel held
    /// and did not answer in time went back to the session's dialog.
    public static func resolvedLine(_ card: WaitingCard) -> String {
        card.call == nil ? "Answered in the terminal" : "Back to the terminal's dialog"
    }

    /// How the panel names an ask it holds, in `returned`.
    public static func heldKey(session: String, call: String) -> String { session + "/" + call }

    /// An ask the panel held is said only when it went back to its dialog
    /// (`returned`): one answered from the panel, by any of its doors, needs
    /// no word.
    public static func resolvedElsewhere(before: [WaitingCard], after: [WaitingCard], actedOn: Set<String>,
                                         returned: Set<String> = []) -> [WaitingCard] {
        let remaining = Set(after.map(\.id))
        return before.filter { card in
            guard card.kind == .permission || card.kind == .question,
                  !remaining.contains(card.id), !actedOn.contains(card.id) else { return false }
            guard let call = card.call else { return true }
            return returned.contains(heldKey(session: card.sessionIds.first ?? "", call: call))
        }
    }

    // MARK: - Keys

    public enum Key: Sendable, Equatable {
        case next, previous, open, markRead
        /// Need a hand into the session (D73): there, and inert until it is.
        case allow, always, deny, reply, option(Int)
    }

    public enum Action: Sendable, Equatable {
        case none, moved, unavailable
        case open(sessionId: String)
        case markRead(sessionIds: [String])
        /// Allow or Deny for an ask the panel holds.
        case answer(sessionId: String, call: String, PermissionGate.Verdict)
        /// One of a held question's options, by index (D86).
        case choose(sessionId: String, call: String, index: Int)
    }

    /// The selected card, by position, kept on its card when the queue changes.
    public struct Cursor: Sendable, Equatable {
        public private(set) var selected: Int

        public init(selected: Int = 0) { self.selected = selected }

        public mutating func press(_ key: Key, cards: [WaitingCard]) -> Action {
            guard !cards.isEmpty else { return .none }
            selected = min(max(selected, 0), cards.count - 1)
            let card = cards[selected]
            switch key {
            case .next:
                guard selected < cards.count - 1 else { return .none }
                selected += 1
                return .moved
            case .previous:
                guard selected > 0 else { return .none }
                selected -= 1
                return .moved
            case .open:
                return card.sessionIds.first.map { .open(sessionId: $0) } ?? .none
            case .markRead:
                // Only what there is to read: a permission read away is a
                // question left unanswered.
                switch card.kind {
                case .failed, .ready, .readyGroup: return .markRead(sessionIds: card.sessionIds)
                default: return .none
                }
            case .allow, .deny:
                guard let call = card.call, card.options.isEmpty, let session = card.sessionIds.first else { return .unavailable }
                return .answer(sessionId: session, call: call, key == .allow ? .allow : .deny)
            case .option(let number):
                guard let call = card.call, card.options.indices.contains(number - 1), let session = card.sessionIds.first
                else { return .unavailable }
                return .choose(sessionId: session, call: call, index: number - 1)
            case .always, .reply:
                return .unavailable
            }
        }

        public mutating func follow(from before: [WaitingCard], to after: [WaitingCard]) {
            guard !after.isEmpty else { selected = 0; return }
            if before.indices.contains(selected), let index = after.firstIndex(where: { $0.id == before[selected].id }) {
                selected = index
            } else {
                selected = min(selected, after.count - 1)
            }
        }
    }

    // MARK: - Internals

    private static func card(_ session: SessionState, _ kind: WaitingCard.Kind, line: String, appearedAt: Date? = nil) -> WaitingCard {
        // An ask's words are part of its id: a second permission in the same
        // turn is a new card, never the first one's armed buttons.
        let ask = kind == .permission || kind == .question ? ":" + line : ""
        return WaitingCard(id: "\(kind.rawValue):\(session.id)\(ask)", kind: kind, sessionIds: [session.id], title: session.displayName,
                    line: line, appearedAt: appearedAt ?? session.statusSince, more: 0)
    }

    /// An ask the panel holds. Its session's row is not amber — no dialog has
    /// been shown — so it is the queue that says the session waits.
    private static func held(_ ask: PermissionGate.Request, in sessions: [SessionState]) -> WaitingCard {
        let title = sessions.first { $0.id == ask.sessionId }?.displayName ?? "A session"
        return WaitingCard(id: "held:\(ask.sessionId):\(ask.callId)", kind: ask.options.isEmpty ? .permission : .question,
                           sessionIds: [ask.sessionId], title: title, line: ask.line, appearedAt: ask.receivedAt, more: 0,
                           call: ask.callId, options: ask.options, impact: ask.impact)
    }

    private static func readyCards(_ ready: [SessionState]) -> [WaitingCard] {
        guard ready.count > readyStandAlone else {
            return ready.map { card($0, .ready, line: firstLine($0.lastMessage) ?? "an answer to read") }
        }
        let sorted = ready.sorted { $0.statusSince < $1.statusSince }
        return [WaitingCard(id: "ready:group", kind: .readyGroup, sessionIds: sorted.map(\.id),
                            title: sorted.map(\.displayName).joined(separator: ", "),
                            line: "\(sorted.count) answers to read", appearedAt: sorted[0].statusSince, more: 0)]
    }

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
    }
}
