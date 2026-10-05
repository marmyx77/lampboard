import Foundation

/// The band above the prompt in every session (UX §8, D84): what waits for the
/// person elsewhere, so they see it, and reach it, from where they are typing.
///
/// What the mod draws comes from here: at most three things, the most urgent
/// first, never the session's own — its own dialog is already in front of it —
/// and only what stops work. An answer to read can wait for the panel.
public enum Band {

    /// One thing, as the band draws it: a digit presses it.
    public struct Item: Equatable, Sendable, Codable {
        public let session: String
        public let title: String
        public let line: String
        public let kind: String
    }

    public static let shown = 3
    static let titleLimit = 32
    static let lineLimit = 60

    /// The kinds that stop work.
    static let kinds: Set<WaitingCard.Kind> = [.permission, .question, .stuck, .failed]

    /// - Parameter lines: `false` gives each item the kind of wait instead of
    ///   its command line, for a session on another machine.
    public static func items(cards: [WaitingCard], excluding session: String?, lines: Bool = true) -> [Item] {
        Array(cards.lazy
            .filter { kinds.contains($0.kind) }
            .filter { card in session.map { !card.sessionIds.contains($0) } ?? true }
            .compactMap { card in
                card.sessionIds.first.map {
                    Item(session: $0, title: cut(card.title, titleLimit),
                         line: lines ? cut(card.line, lineLimit) : said(card.kind), kind: card.kind.rawValue)
                }
            }
            .prefix(shown))
    }

    /// The wire to the mod: version 1, the items in order.
    public static func json(_ items: [Item]) -> Data {
        let body: [String: Any] = [
            "v": 1,
            "items": items.map { ["session": $0.session, "title": $0.title, "line": $0.line, "kind": $0.kind] },
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(#"{"items":[],"v":1}"#.utf8)
    }

    /// One line as a permission card reads it (`ModReport.detail`): secrets
    /// masked, no control, format or separator character — no bidi override
    /// can reorder it — cut by characters with an ellipsis. A hook's ask is
    /// not masked on its way in, and the band goes to every session.
    static func cut(_ text: String, _ limit: Int) -> String {
        let line = ModReport.detail(text) ?? ""
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }

    static func said(_ kind: WaitingCard.Kind) -> String {
        switch kind {
        case .permission: return "a permission"
        case .question: return "a question"
        case .stuck: return "possibly stuck"
        case .failed: return "the turn failed"
        default: return "waiting"
        }
    }
}
