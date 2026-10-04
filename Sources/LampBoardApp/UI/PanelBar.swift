import AppKit
import Combine
import LampBoardCore

/// The bar at the top of the wide panel wired in (D77): what it searches, what
/// its results do, `⌘K` while the panel holds the keyboard, and the panel
/// remeasured when its results come and go.
///
/// Its own file for the reason `PanelQueue.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    func wireBar() {
        bar.onOpenSession = { [weak self] id in
            guard let self, let session = self.store.state.sessions[id] else { return }
            self.activate(session: session)
        }
        bar.onAction = { [weak self] action in
            switch action {
            case .settings: self?.onOpenSettings?()
            case .gettingStarted: GettingStartedWindowController.shared.show()
            case .tour: TrialLauncher.startFromMenu()
            case .checkForUpdates: self?.checkForUpdates()
            case .legend: self?.onOpenLegend?()
            }
        }
        // The same door a session's MCP call comes through: the same switch,
        // limits and daily ceiling (D62), and the answer drawn for the person.
        bar.onAsk = { [weak self] question in
            guard let lampMaster = self?.lampMaster else { return "LampMaster is not available." }
            let body = (try? JSONSerialization.data(withJSONObject: [
                "tool": LampMasterMCP.Tool.askLampMaster.rawValue, "arguments": ["question": question],
            ])) ?? Data()
            return await lampMaster.tool(body).text
        }
        bar.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.resizeToFit(self.store.state)
        }
        barKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, !self.isCompact,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "k" else { return event }
            self.bar.focus()
            return nil
        }
        barHotKey = GlobalHotKey { [weak self] in self?.summonBar() }
        barHotKey?.apply(preferences.barShortcut)
        NotificationCenter.default.publisher(for: .barShortcutChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.barHotKey?.apply(self.preferences.barShortcut)
            }
            .store(in: &cancellables)

        // The switch decides whether a question can be asked, and the bar says so.
        lampMaster?.$snapshot
            .map(\.enabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBar() }
            .store(in: &cancellables)
        refreshBar()
    }

    /// The shortcut from anywhere: the panel comes up holding the keyboard, its
    /// bar open. Without activating the app — the panel is non-activating, so
    /// the application underneath stays the active one.
    func summonBar() {
        panel.orderFrontRegardless()
        panel.makeKey()
        guard !isCompact else { return }
        bar.focus()
    }

    func refreshBar() {
        bar.update(rows: currentRendering.rows, lampMasterEnabled: lampMaster?.snapshot.enabled ?? false)
    }
}
