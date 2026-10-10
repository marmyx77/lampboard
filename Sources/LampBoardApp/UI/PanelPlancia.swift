import AppKit
import Combine
import LampBoardCore

/// The Plancia wired in (UX §1, §5, D79): opening a session beside the list,
/// `⌘⇧L` through the depths, `Esc` back to the panel, and the Plancia closing
/// by itself when the pointer has been elsewhere with nothing waiting.
///
/// Its own file for the reason `PanelQueue.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    /// Whether a text field or view in the panel has the keyboard — the bar's,
    /// the Plancia's composer. Single keys belong to it then: a queue key read
    /// out of a sentence typed in the composer would answer a permission (a
    /// review finding), and `Esc` there would throw the draft away.
    var isTyping: Bool { panel.firstResponder is NSText }

    /// The Plancia needs room for a conversation, whatever the column needs.
    static let planciaMinimumHeight: CGFloat = 520

    func wirePlancia() {
        planciaKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌘⇧L from the Hub too: there it closes the round, back to the column.
            if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "l",
               self.hubIsKey?() == true || (self.panel.isKeyWindow && !self.bar.isEditing && !self.isTyping) {
                self.cycleDepth()
                return nil
            }
            guard self.panel.isKeyWindow, !self.bar.isEditing, !self.isTyping else { return event }
            // Esc closes the Plancia and nothing else: narrowing the panel to a
            // column on a key somebody presses to dismiss things would surprise.
            if event.keyCode == 53, modifiers.isEmpty, self.plancia.isOpen {
                self.closePlancia()
                return nil
            }
            return event
        }
        // A session that ends while open closes the Plancia: its composer would
        // otherwise take a message nothing will ever deliver.
        store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, let id = self.plancia.sessionId, state.session(named: id) == nil else { return }
                self.closePlancia()
            }
            .store(in: &cancellables)
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.closePlanciaIfAway() }
            .store(in: &cancellables)
    }

    func openPlancia(sessionId: String) {
        guard let session = session(named: sessionId), !session.workspace.isRemote else { return }
        if isCompact { toggleCompact() }
        // The side is chosen once, from the narrow panel, and kept until it
        // closes: read again from the wide frame it could flip mid-use.
        if !plancia.isOpen { plancia.leading = planciaLeading }
        widthKeepsRight = plancia.leading
        plancia.open(session, store: store)
        planciaAwaySince = nil
        rebuildContent()
    }

    /// What the Plancia header's buttons do (UX §5): the row's own actions.
    func planciaActions() -> PlanciaActions {
        PlanciaActions(
            go: { [weak self] id in
                guard let self, let session = self.session(named: id) else { return }
                self.activate(session: session)
            },
            handOver: { [weak self] id in
                guard let self, let session = self.session(named: id),
                      let name = RowActivity.flat(session.displayName).split(separator: " ").first else { return }
                // The bar names this one; the person names who takes over (D91).
                self.bar.focus()
                self.bar.text = "/handoff @\(name) @"
            },
            toggleMuted: { [weak self] id in
                guard let self, let session = self.session(named: id) else { return }
                self.preferences.mutedWorkspaces = Preferences.toggling(session.workspace.key, in: self.preferences.mutedWorkspaces)
                self.rebuildContent()
            },
            isMuted: { [weak self] id in
                guard let self, let session = self.session(named: id) else { return false }
                return self.preferences.mutedWorkspaces.contains(session.workspace.key)
            },
            toggleFocus: { [weak self] id in self?.toggleFocus(sessionId: id) },
            isFocused: { [weak self] id in self?.preferences.focusedSession == id }
        )
    }

    /// One session in the foreground (§5.3, G1), or none: the same id again takes
    /// it off, and the notifier says what waited.
    func toggleFocus(sessionId: String) {
        preferences.focusedSession = preferences.focusedSession == sessionId ? nil : sessionId
        onFocusChanged?(preferences.focusedSession)
        rebuildContent()
    }

    /// LampMaster's Plancia (UX §4): beside the list, like a session's.
    func openLampMasterPlancia(sheet: LampMasterPlanciaContent.Sheet = .suggestions) {
        if isCompact { toggleCompact() }
        if !plancia.isOpen { plancia.leading = planciaLeading }
        widthKeepsRight = plancia.leading
        plancia.openLampMaster(sheet: sheet)
        lampMaster?.request(.opened)
        planciaAwaySince = nil
        rebuildContent()
    }

    func closePlancia() {
        guard plancia.isOpen else { return }
        widthKeepsRight = plancia.leading
        plancia.close()
        rebuildContent()
    }

    /// `⌘⇧L`: the column, the panel, the Plancia on what is most urgent, and
    /// back to the column.
    /// What the composer's Send does, for `--plancia-send` on a fake home:
    /// waits for a row and its Plancia, up to a minute, then sends once.
    func sendFromPlancia(_ text: String, attempts: Int = 30) {
        guard let thread = plancia.thread else {
            guard attempts > 0 else { return Diagnostics.log("plancia-send: no Plancia open") }
            if !store.state.sessions.isEmpty { cycleDepth() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sendFromPlancia(text, attempts: attempts - 1) }
            return
        }
        // Pinned, so it stays to be photographed once the queue empties.
        plancia.pinned = true
        Diagnostics.log("plancia-send: \(thread.send(text) ? "sent" : "refused")")
    }

    /// A digit pressed in a session's band (D84): the panel comes up with that
    /// session open — its Plancia here, the session itself on another machine.
    @discardableResult
    func openFromBand(_ id: String) -> Bool {
        guard let session = session(named: id) else { return false }
        Diagnostics.log("band: \(id.prefix(8)) opened from a session's band")
        panel.orderFrontRegardless()
        if isCompact { toggleCompact() }
        if session.workspace.isRemote { activate(session: session) }
        else if let openHub { openHub(session.id) } else { openPlancia(sessionId: session.id) }
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
        } else if plancia.isOpen {
            closePlancia()
            toggleCompact()
        } else if let id = queue.cards.first?.sessionIds.first ?? currentRendering.rows.first?.primary.id {
            if let openHub { openHub(id) } else { openPlancia(sessionId: id) }
        } else {
            toggleCompact()
        }
    }

    func session(named id: String) -> SessionState? { store.state.session(named: id) }

    /// The side toward the middle of the screen: a panel on the right half
    /// opens its Plancia to the left.
    var planciaLeading: Bool {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return false }
        return panel.frame.midX > visible.midX
    }

    /// The anchor for a new width: the edge the Plancia chose when it is the
    /// Plancia opening or closing, else the edge nearest the side (D78).
    func widthAnchor(to width: CGFloat) -> CGPoint {
        defer { if width != panel.frame.width { widthKeepsRight = nil } }
        let frame = panel.frame
        if let keepRight = widthKeepsRight, width != frame.width {
            return CGPoint(x: keepRight ? frame.maxX - width : frame.minX, y: frame.maxY)
        }
        return PanelPlacement.anchor(widening: frame, to: width, in: (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame)
    }

    func planciaHeight(_ height: CGFloat) -> CGFloat {
        plancia.isOpen ? max(height, Self.planciaMinimumHeight) : height
    }

    private func closePlanciaIfAway() {
        guard plancia.isOpen else { planciaAwaySince = nil; return }
        if panel.frame.contains(NSEvent.mouseLocation) {
            planciaAwaySince = nil
            return
        }
        let since = planciaAwaySince ?? Date()
        planciaAwaySince = since
        if PanelDepth.closesPlancia(queueEmpty: queue.cards.isEmpty, pointerAwayFor: Date().timeIntervalSince(since),
                                    pinned: plancia.pinned) {
            closePlancia()
        }
    }
}
