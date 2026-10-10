import AppKit
import ClarcChatKit
import SwiftUI

/// The conversation in the Hub's colours (the proposal's dark palette): the
/// person's messages in a soft blue bubble on the right, the replies as plain
/// text, tools in thin outlined lines. Clarc's palette is one for the app, so
/// the Hub sets it when its window comes forward, and a live window sets its
/// own when it does (LiveChatTheme).
@MainActor
enum HubChatTheme {

    static func apply() {
        let ink = HubPalette.ink
        let store = ThemeStore.shared
        store.colors = ThemeColors(
            accent: HubPalette.accent, accentSubtle: HubPalette.accentSoft,
            background: HubPalette.panel, surfacePrimary: HubPalette.panel, surfaceSecondary: HubPalette.soft,
            surfaceTertiary: HubPalette.soft, surfaceElevated: HubPalette.soft,
            sidebarBackground: HubPalette.soft, sidebarItemHover: HubPalette.accentSoft, sidebarItemSelected: HubPalette.accentSoft,
            textPrimary: ink, textSecondary: HubPalette.muted, textTertiary: HubPalette.muted.opacity(0.8),
            border: HubPalette.line, borderSubtle: HubPalette.line.opacity(0.6),
            codeBackground: HubPalette.soft, codeHeaderBackground: HubPalette.line,
            userBubble: HubPalette.accentSoft, userBubbleText: ink,
            assistantBubble: Color.clear,
            statusSuccess: HubPalette.green, statusError: HubPalette.red, statusWarning: HubPalette.amber,
            inputBackground: HubPalette.panel, inputBorder: HubPalette.line)
        store.messageFontSizeAdjustment = -1
        store.messageFontFamily = nil
    }
}
