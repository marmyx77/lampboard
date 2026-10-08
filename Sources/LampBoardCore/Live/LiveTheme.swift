import Foundation

/// How the live view looks (D130).
///
/// **The frame takes the theme, the terminal keeps its colours.** The window's
/// backdrop, the card behind the session and the text the terminal draws by
/// default follow the theme; the sixteen ANSI colours stay the terminal's, because
/// Claude Code paints its syntax, its diffs and its prompts with them, and a
/// palette chosen for the frame would make those unreadable. AgentHub reached
/// the same rule after trying the other one.
///
/// The card is also the terminal's background, so the bands Claude Code paints
/// for itself sit on the colour they were chosen against.
public struct LiveTheme: Equatable, Sendable {
    public let id: String
    public let name: String
    /// The window behind the card, top to bottom.
    public let backdropTop: String
    public let backdropBottom: String
    /// The card, and the terminal's own background.
    public let card: String
    /// The terminal's default text.
    public let text: String
    /// Dark themes ask for a dark window chrome.
    public let isDark: Bool

    public static let defaultId = "night"

    public static let presets: [LiveTheme] = [
        LiveTheme(id: "night", name: "Night", backdropTop: "#141a2e", backdropBottom: "#2a1a3a",
                  card: "#13151f", text: "#e4e6ef", isDark: true),
        LiveTheme(id: "lagoon", name: "Lagoon", backdropTop: "#0b2a2f", backdropBottom: "#10233d",
                  card: "#0f1a1f", text: "#e0f0ee", isDark: true),
        LiveTheme(id: "ember", name: "Ember", backdropTop: "#2b1612", backdropBottom: "#3a2414",
                  card: "#1a1210", text: "#f3e6dc", isDark: true),
        LiveTheme(id: "paper", name: "Paper", backdropTop: "#eceef3", backdropBottom: "#dfe3ec",
                  card: "#fbfbfd", text: "#1d2230", isDark: false),
    ]

    public static func named(_ id: String?) -> LiveTheme {
        presets.first { $0.id == id } ?? presets.first { $0.id == defaultId }!
    }

    /// Points. Below ten the interface's box drawing smears; above twenty-four
    /// a laptop shows too few columns for Claude Code's own layout.
    public static let fontSizes: ClosedRange<Double> = 10...24
    public static let defaultFontSize: Double = 13

    public static func clampedFontSize(_ size: Double) -> Double {
        min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }

    /// `#rrggbb` as three components between 0 and 1.
    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// WCAG contrast ratio between two colours, 1 to 21.
    public static func contrast(_ a: String, _ b: String) -> Double {
        guard let x = rgb(a), let y = rgb(b) else { return 1 }
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        let (l1, l2) = (luminance(x), luminance(y))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
