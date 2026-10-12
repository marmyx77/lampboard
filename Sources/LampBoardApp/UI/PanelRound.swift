import AppKit
import LampBoardCore

/// The round of depths, `⌘⇧L`: the column, the panel, the Hub, and back to the
/// column (D149). The Hub took the Plancia's place, and with 2.1 its last part
/// too: what was proposed into a Plancia waits in the session's terminal in the
/// Hub (D165).
///
/// Its own file for the reason `PanelQueue.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    /// Whether a text field in the panel has the keyboard — the bar's. Single
    /// keys belong to it then: a queue key read out of a sentence typed in the
    /// bar would answer a permission (a review finding).
    var isTyping: Bool { panel.firstResponder is NSText }

    func wireRound() {
        roundKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌘⇧L from the Hub too: there it closes the round, back to the column.
            if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "l",
               self.hubIsKey?() == true || (self.panel.isKeyWindow && !self.bar.isEditing && !self.isTyping) {
                self.cycleDepth()
                return nil
            }
            return event
        }
    }

    /// One session in the foreground (§5.3, G1), or none: the same id again takes
    /// it off, and the notifier says what waited.
    func toggleFocus(sessionId: String) {
        preferences.focusedSession = preferences.focusedSession == sessionId ? nil : sessionId
        onFocusChanged?(preferences.focusedSession)
        rebuildContent()
    }

    /// LampMaster in the Hub: its own session and its cards (D164). Opening it
    /// asks for a round when the last one is stale.
    func openLampMasterInHub() {
        openHub?(HubModel.lampMasterId)
        lampMaster?.request(.opened)
    }

    /// A digit pressed in a session's band (D84): the session in the Hub.
    @discardableResult
    func openFromBand(_ id: String) -> Bool {
        guard let session = session(named: id) else { return false }
        Diagnostics.log("band: \(id.prefix(8)) opened from a session's band")
        panel.orderFrontRegardless()
        if isCompact { toggleCompact() }
        if let openHub { openHub(session.id) } else { activate(session: session) }
        return true
    }

    func cycleDepth() {
        if hubIsOpen?() == true {
            // The round's last depth: the Hub closes and the column comes back.
            closeHub?()
            if !isCompact { toggleCompact() }
            // The keys come back to the column, for the next ⌘⇧L to reach it:
            // after the Hub's close is done, or the window server gives them away.
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.panel.makeKeyAndOrderFront(nil)
            }
        } else if isCompact {
            toggleCompact()
        } else if let openHub {
            openHub(queue.cards.first?.sessionIds.first ?? currentRendering.rows.first?.primary.id)
        } else {
            toggleCompact()
        }
    }

    func session(named id: String) -> SessionState? { store.state.session(named: id) }

    /// The anchor for a new width: the edge nearest the side (D78).
    func widthAnchor(to width: CGFloat) -> CGPoint {
        let frame = panel.frame
        return PanelPlacement.anchor(widening: frame, to: width, in: (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame)
    }
}
