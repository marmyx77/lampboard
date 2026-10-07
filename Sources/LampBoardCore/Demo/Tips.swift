import Foundation

/// A line the first time something happens (U5): what it means and what can be
/// done about it, said when it is on screen rather than in a tour beforehand.
///
/// Each tip once, ever, and one a day at most, whichever it is: a panel that
/// lectures is a panel people learn to look away from.
public enum Tips {

    public enum Tip: String, CaseIterable, Sendable {
        case needsYou, stopped, usageHigh, manyRows, resting

        public var text: String {
            switch self {
            case .needsYou:
                return "Amber blinks: a session waits for you. Click it, or answer from here with the helper."
            case .stopped:
                return "A red lamp: that turn stopped before its answer. Point at the row to read why."
            case .usageHigh:
                return "Four fifths of your five-hour window are used. A row's More menu offers a lighter model."
            case .manyRows:
                return "Six sessions or more: ⌘K finds one by a few letters; a row's menu hides a project."
            case .resting:
                return "Rows quiet for twelve hours fold into «Resting» at the foot. A click lists them."
            }
        }
    }

    /// What the panel shows now, as far as the tips care.
    public struct Facts: Equatable, Sendable {
        public let stopped: Bool
        public let needsYou: Bool
        public let usagePercent: Int?
        public let rowCount: Int
        public let resting: Bool

        public init(stopped: Bool, needsYou: Bool, usagePercent: Int?, rowCount: Int, resting: Bool) {
            self.stopped = stopped
            self.needsYou = needsYou
            self.usagePercent = usagePercent
            self.rowCount = rowCount
            self.resting = resting
        }
    }

    public static let usageThreshold = 80
    public static let manyRows = 6
    public static let gap: TimeInterval = 86_400

    /// The tip to show now, if any. `shown` is every tip shown so far, by raw
    /// value, with when.
    public static func next(_ facts: Facts, shown: [String: Date], now: Date) -> Tip? {
        if let last = shown.values.max(), now.timeIntervalSince(last) < gap { return nil }
        return Tip.allCases.first { holds($0, facts) && shown[$0.rawValue] == nil }
    }

    /// Whether what a tip speaks of is on screen: the tip is offered then, and
    /// goes by itself once it is not.
    public static func holds(_ tip: Tip, _ facts: Facts) -> Bool {
        switch tip {
        case .needsYou: return facts.needsYou
        case .stopped: return facts.stopped
        case .usageHigh: return (facts.usagePercent ?? 0) >= usageThreshold
        case .manyRows: return facts.rowCount >= manyRows
        case .resting: return facts.resting
        }
    }
}
