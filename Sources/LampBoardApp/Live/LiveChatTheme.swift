import AppKit
import ClarcChatKit
import LampBoardCore
import SwiftUI

/// The chat in the live window's own colours and text (D147): Clarc's palette
/// is made from the theme's card and text, its messages set in the chat font
/// VS Code uses here when there is one, at the live view's text size.
@MainActor
enum LiveChatTheme {

    static func apply(_ appearance: LiveAppearance, chatFont: String?) {
        let theme = appearance.theme
        let card = Color(nsColor: NSColor(liveHex: theme.card))
        let text = Color(nsColor: NSColor(liveHex: theme.text))
        let ink = theme.isDark ? Color.white : Color.black
        let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
        let store = ThemeStore.shared
        store.colors = ThemeColors(
            accent: accent, accentSubtle: accent.opacity(0.15),
            background: card, surfacePrimary: card, surfaceSecondary: ink.opacity(0.04),
            surfaceTertiary: ink.opacity(0.07), surfaceElevated: ink.opacity(0.05),
            sidebarBackground: card, sidebarItemHover: ink.opacity(0.05), sidebarItemSelected: ink.opacity(0.08),
            textPrimary: text, textSecondary: text.opacity(0.72), textTertiary: text.opacity(0.5),
            border: ink.opacity(0.14), borderSubtle: ink.opacity(0.07),
            codeBackground: ink.opacity(0.06), codeHeaderBackground: ink.opacity(0.09),
            userBubble: ink.opacity(theme.isDark ? 0.10 : 0.07), userBubbleText: text,
            assistantBubble: Color.clear,
            statusSuccess: Color(red: 0.2, green: 0.6, blue: 0.3), statusError: Color(red: 0.8, green: 0.25, blue: 0.2),
            statusWarning: Color(red: 0.85, green: 0.55, blue: 0.1),
            inputBackground: ink.opacity(0.04), inputBorder: ink.opacity(0.14))
        // Clarc's messages are drawn around fourteen points.
        store.messageFontSizeAdjustment = Int((appearance.fontSize - 14).rounded())
        store.messageFontFamily = chatFont
    }

    /// The first family of VS Code's chat font that this Mac has.
    static func vsCodeChatFont() -> String? {
        VSCodeReader.chatFontFamilies().first { NSFontManager.shared.availableFontFamilies.contains($0) }
    }
}
