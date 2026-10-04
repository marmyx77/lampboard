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

    public static func cards(sessions: [SessionState], suggestions: [LampMasterShown], now: Date) -> [WaitingCard] {
        var cards: [WaitingCard] = []
        var ready: [SessionState] = []
        for session in sessions {
            // The state the row shows, not the one beneath it: with a subagent
            // alive, a finished or failed parent is blue, and a queue calling it
            // green would be the lie D22 removed from the row.
            switch session.status {
            case .awaiting:
                let question = session.pendingAsk?.tool == "AskUserQuestion"
                cards.append(card(session, question ? .question : .permission,
                                  line: session.pendingAsk?.sentence ?? SessionStatus.awaiting.label))
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
    public static func resolvedElsewhere(before: [WaitingCard], after: [WaitingCard], actedOn: Set<String>) -> [WaitingCard] {
        let remaining = Set(after.map(\.id))
        return before.filter {
            ($0.kind == .permission || $0.kind == .question) && !remaining.contains($0.id) && !actedOn.contains($0.id)
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
            case .allow, .always, .deny, .reply, .option:
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
