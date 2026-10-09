import Foundation

/// «Like my VS Code» (D144): the live view in the colours of the VS Code on this
/// Mac, read from its own files rather than guessed.
///
/// What a person sees in VS Code's chat is its side bar: its background and
/// text, then the editor's when the side bar does not say. The terminal's
/// sixteen colours come from the same place they do in VS Code's terminal. Each
/// value is the profile's own customisation first, the colour theme's second.
public enum VSCodeTheme {

    /// The colours a live window takes.
    public struct Colors: Equatable, Sendable {
        public let background: String
        public let text: String
        /// Sixteen, black to bright white, or `nil` when the theme does not say
        /// them all and the default palette for its brightness is used.
        public let ansi: [String]?
        public let isDark: Bool

        public init(background: String, text: String, ansi: [String]?, isDark: Bool) {
            self.background = background
            self.text = text
            self.ansi = ansi
            self.isDark = isDark
        }
    }

    /// VS Code's settings are JSON with comments and trailing commas.
    public static func parse(_ text: String) -> [String: Any]? {
        guard let data = strippingComments(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Comments out, trailing commas out, strings left as they are.
    static func strippingComments(_ text: String) -> String {
        var out = ""
        var chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        // A comma followed only by blanks and a closing bracket goes.
        chars = Array(out)
        var cleaned = ""
        inString = false
        for (index, c) in chars.enumerated() {
            if c == "\"", index == 0 || chars[index - 1] != "\\" { inString.toggle() }
            if !inString, c == "," {
                let rest = chars[(index + 1)...].first { !$0.isWhitespace }
                if rest == "}" || rest == "]" { continue }
            }
            cleaned.append(c)
        }
        return cleaned
    }

    public static let ansiKeys = [
        "terminal.ansiBlack", "terminal.ansiRed", "terminal.ansiGreen", "terminal.ansiYellow",
        "terminal.ansiBlue", "terminal.ansiMagenta", "terminal.ansiCyan", "terminal.ansiWhite",
        "terminal.ansiBrightBlack", "terminal.ansiBrightRed", "terminal.ansiBrightGreen", "terminal.ansiBrightYellow",
        "terminal.ansiBrightBlue", "terminal.ansiBrightMagenta", "terminal.ansiBrightCyan", "terminal.ansiBrightWhite",
    ]

    /// The theme a live window takes from them: the card is the chat's
    /// background, the window behind it a shade darker.
    public static func liveTheme(_ colors: Colors) -> LiveTheme {
        LiveTheme(id: LiveTheme.fromVSCodeId, name: "Like my VS Code",
                  backdropTop: shade(colors.background, by: 0.06), backdropBottom: shade(colors.background, by: 0.11),
                  card: colors.background, text: colors.text, isDark: colors.isDark, ansi: colors.ansi)
    }

    static func shade(_ hex: String, by amount: Double) -> String {
        guard let (r, g, b) = LiveTheme.rgb(hex) else { return hex }
        let f = { (v: Double) in String(format: "%02x", Int((v * (1 - amount)) * 255 + 0.5)) }
        return "#" + f(r) + f(g) + f(b)
    }

    /// The colours, from the profile's settings over the theme's own colours.
    /// `nil` when neither says a background.
    public static func colors(settings: [String: Any], themeName: String?, themeColors: [String: String]) -> Colors? {
        var custom = settings["workbench.colorCustomizations"] as? [String: Any] ?? [:]
        // Customisations scoped to the theme in use win over the general ones.
        if let themeName, let scoped = custom["[\(themeName)]"] as? [String: Any] {
            custom.merge(scoped) { _, new in new }
        }
        func color(_ keys: [String]) -> String? {
            for key in keys {
                if let value = custom[key] as? String, let hex = hex6(value) { return hex }
                if let value = themeColors[key], let hex = hex6(value) { return hex }
            }
            return nil
        }
        guard let background = color(["sideBar.background", "panel.background", "editor.background"]) else { return nil }
        let isDark = luminance(background) < 0.5
        let text = color(["sideBar.foreground", "foreground", "editor.foreground"]) ?? (isDark ? "#cccccc" : "#1f1f1f")
        let ansi = ansiKeys.compactMap { color([$0]) }
        return Colors(background: background, text: text, ansi: ansi.count == 16 ? ansi : nil, isDark: isDark)
    }

    /// The fixed-width sibling of the chat's font, when this Mac has one:
    /// `Atkinson Hyperlegible` → `Atkinson Hyperlegible Mono`.
    public static func monoSibling(of family: String?, among installed: [String]) -> String? {
        guard let family = family?.split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")), !family.isEmpty else { return nil }
        if installed.contains(family) { return family }
        return [family + " Mono", family + "Mono"].first { installed.contains($0) }
    }

    /// `#rrggbb` from `#rgb`, `#rrggbb` or `#rrggbbaa` (the alpha dropped).
    public static func hex6(_ value: String) -> String? {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 3: return "#" + digits.map { "\($0)\($0)" }.joined().lowercased()
        case 6, 8: return "#" + digits.prefix(6).lowercased()
        default: return nil
        }
    }

    public static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = LiveTheme.rgb(hex) else { return 1 }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
