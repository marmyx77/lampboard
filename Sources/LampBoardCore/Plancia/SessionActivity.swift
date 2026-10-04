import Foundation

/// What one session has been doing, for the Plancia's Activity tab (UX §5):
/// tools with their durations and turns with what each cost, the newest kept.
///
/// Fed by the companion mod's reports and the hooks' turn ends; held in memory
/// only, since it is a view of now rather than a record.
public struct SessionActivity: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case tool(name: String, detail: String?)
        case turn
    }

    public struct Entry: Sendable, Equatable {
        public let at: Date
        public let kind: Kind
        /// How long a tool ran; `nil` while it runs and for a turn.
        public var seconds: Double?
        /// What a turn cost, from the mod's running total.
        public var costUSD: Double?
        /// The tool call it belongs to, to match its end.
        let call: String?
    }

    /// Two screens of activity: a focused session is looked at for what it did
    /// lately, and a long day of tools would grow without bound.
    public static let kept = 60

    public private(set) var entries: [Entry] = []
    private var lastCost: Double?
    private var costAtLastTurn: Double?

    public init() {}

    public mutating func toolStarted(id: String, tool: String, detail: String?, at date: Date) {
        append(Entry(at: date, kind: .tool(name: tool, detail: detail.map(Self.line)), seconds: nil, costUSD: nil, call: id))
    }

    /// Fills the duration of the tool `id`; an end without its start adds nothing.
    public mutating func toolEnded(id: String, at date: Date) {
        guard let index = entries.lastIndex(where: { $0.call == id && $0.seconds == nil }) else { return }
        entries[index].seconds = max(0, date.timeIntervalSince(entries[index].at))
    }

    /// The mod's running total for the session.
    public mutating func costReported(_ usd: Double, at date: Date) {
        lastCost = usd
    }

    /// What the companion mod reported, as far as this log is concerned: a
    /// tool's start or end, and the session's running cost.
    public mutating func record(_ report: ModReport, at date: Date) {
        switch report {
        case .tool(_, let run):
            if run.finished { toolEnded(id: run.id, at: date) } else { toolStarted(id: run.id, tool: run.tool, detail: run.detail, at: date) }
        case .measure(_, let measure):
            if let usd = measure.costUSD { costReported(usd, at: date) }
        case .start, .end:
            break
        }
    }

    public mutating func turnEnded(at date: Date) {
        let cost = lastCost.map { total in total - (costAtLastTurn ?? 0) }
        costAtLastTurn = lastCost ?? costAtLastTurn
        append(Entry(at: date, kind: .turn, seconds: nil, costUSD: cost, call: nil))
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
    }

    /// One line, cut: a heredoc's body never reaches the Plancia.
    private static func line(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return RowActivity.flat(first).count > 120 ? String(RowActivity.flat(first).prefix(119)) + "…" : RowActivity.flat(first)
    }
}
