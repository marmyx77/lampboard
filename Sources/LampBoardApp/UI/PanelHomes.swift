import AppKit
import LampBoardCore

/// The panel's two homes, and the lamp that stands for it in the menu bar.
///
/// A separate file because `PanelController` had reached the length this project
/// refuses — eight hundred lines, checked by `check-docs.sh` — and the honest
/// answer to that is to take a whole subject out rather than to raise the
/// number. Everything here is about *where the panel is*: nothing in it decides
/// what a row says, and nothing outside it decides where the window sits.
extension PanelController {

    // MARK: - The two homes

    /// Puts the panel where it belongs and the lamp where it was asked for.
    ///
    /// - Parameter showing: whether the panel should be on screen afterwards. A
    ///   panel that lives in the menu bar starts put away, because a drop-down
    ///   that is already down at login is not a drop-down.
    func applyHome(showing: Bool) {
        panel.adopt(home: home)
        // The one direction that is forced: nothing but the lamp can bring a
        // panel back from the menu bar, so moving it there turns the lamp on.
        if preferences.showsMenuBarIcon || home.requiresMenuBarIcon {
            lamp.show()
            lamp.update(currentSummary)
        } else {
            lamp.hide()
        }
        panel.onResignKey = home.closesWhenUnfocused
            ? { [weak self] in self?.dismissDropDown() }
            : nil

        if showing {
            if home == .menuBar {
                positionUnderLamp()
            } else {
                returnToItsOwnCorner()
            }
            panel.orderFrontRegardless()
            if home == .menuBar { panel.makeKey() }
        } else {
            panel.orderOut(nil)
        }
        Diagnostics.log("panel home=\(home.rawValue) lamp=\(lamp.isVisible) showing=\(showing)")
        if home == .menuBar { checkTheLampCanBeSeen() }
    }

    /// A home whose only door is a lamp the system will not draw is not a home.
    ///
    /// The menu bar can be full, and `NSStatusItem` does not say so — it hands
    /// out an item, reports it visible, and draws nothing (`MenuBarPlacement`
    /// carries the measurement). The panel then lives behind a lamp that is not
    /// there: the app is running, the server answers, and nothing a person knows
    /// how to do opens it. That was reported from use as *it doesn't start any
    /// more*, which was the only reasonable reading.
    ///
    /// So the lamp is asked where it landed, and a panel with no reachable lamp
    /// goes back to its own window and says why.
    ///
    /// - Parameter attempt: how many times the frame has been asked for already.
    ///   It is not laid out at once — measured at `(0, 0, 28, 0)` on the turn it
    ///   is created and settled about three tenths of a second later — so an
    ///   answer of *not yet* is retried rather than believed.
    func checkTheLampCanBeSeen(attempt: Int = 0) {
        guard home == .menuBar else { return }
        switch lamp.placement {
        case .reachable:
            return
        case .notYetPlaced where attempt < Self.lampSettlingAttempts:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lampSettlingDelay) { [weak self] in
                self?.checkTheLampCanBeSeen(attempt: attempt + 1)
            }
        case .notYetPlaced, .unreachable:
            // A lamp that never got a frame is a lamp that is not there, and after
            // two seconds the two answers mean the same thing on screen. The error
            // is deliberately made in this direction: rescuing a panel that did not
            // need it costs somebody one alert and a window back in its corner,
            // where leaving a panel nobody can open costs them the application.
            rescueFromTheMenuBar()
        }
    }

    /// Every tenth of a second the lamp is given to settle, and how many times.
    /// Two seconds in total: measured, it needs three tenths.
    private static let lampSettlingDelay: TimeInterval = 0.4
    private static let lampSettlingAttempts = 5

    /// Brings the panel home when the menu bar had no room for its lamp.
    private func rescueFromTheMenuBar() {
        Diagnostics.log("no room in the menu bar for the lamp: the panel comes back to its window")
        home = .floating
        preferences.home = .floating
        applyHome(showing: true)
        rebuildContent()
        Alerts.tell(
            title: "The menu bar had no room for the lamp",
            message: "The panel is back in its own window, because nothing else could "
                + "have opened it up there. The lamp stays switched on and appears "
                + "again as soon as the bar has room for it."
        )
    }

    /// Puts the panel in front of whoever just asked for it.
    ///
    /// This is what starting the app a second time does, which is the gesture
    /// somebody makes when they believe it is not running — and, before this
    /// existed, the gesture that did nothing at all: an accessory application
    /// that is already running has no window to raise and no Dock icon to bounce,
    /// so a panel living in the menu bar behind a lamp nobody drew stayed exactly
    /// as invisible as it had been.
    func summon() {
        switch home {
        case .floating:
            // A panel saved on a screen that is no longer attached is the same
            // stranding by another route, and this is the moment to undo it.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                returnToItsOwnCorner()
            }
            panel.orderFrontRegardless()
        case .menuBar:
            guard lamp.placement != .unreachable else {
                rescueFromTheMenuBar()
                return
            }
            if panel.isVisible {
                panel.orderFrontRegardless()
            } else {
                toggleDropDown()
            }
        }
        Diagnostics.log("summoned: home=\(home.rawValue) frame=\(panel.frame)")
    }

    func wireLamp() {
        lamp.onToggle = { [weak self] in self?.toggleDropDown() }
        lamp.onContextMenu = { [weak self] button in
            guard let self else { return }
            self.lampMenu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.maxY + 4),
                in: button
            )
        }
    }

    /// The lamp's own menu, on a right-click.
    ///
    /// Deliberately short. The panel carries every switch this app has, and it is
    /// one click away; what belongs up here is the handful of things somebody
    /// would want *without* opening it — where the panel lives, whether the lamp
    /// stays, and the way out.
    func lampMenu() -> NSMenu {
        let menu = NSMenu()
        menuTargets = []

        func add(_ title: String, enabled: Bool = true, tip: String? = nil, _ run: @escaping () -> Void) {
            let target = MenuAction(run)
            menuTargets.append(target)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
            item.toolTip = tip
            menu.addItem(item)
        }

        add(home == .menuBar
            ? "Put the panel back in its own window"
            : "Put the panel in the menu bar") { [weak self] in self?.toggleHome() }
        add("Open the conversations…") { [weak self] in self?.openExtendedWindow() }
        add("Settings…") { [weak self] in self?.onOpenSettings?() }
        menu.addItem(.separator())
        // Greyed rather than absent when it would strand the panel: an entry that
        // disappears teaches nothing, and this one has a reason worth reading.
        add("Hide this lamp",
            enabled: home != .menuBar,
            tip: home == .menuBar
                ? "The panel lives up here, so nothing else could bring it back."
                : nil) { [weak self] in self?.toggleMenuBarIcon() }
        menu.addItem(.separator())
        add("Quit LampBoard") { NSApp.terminate(nil) }

        // A menu built with `autoenablesItems` on asks a validator about every
        // entry and greys the ones nobody answers for, which here is all of them.
        menu.autoenablesItems = false
        return menu
    }


    /// The lamp was clicked: down if it was up, up if it was down.
    ///
    /// In the floating home the lamp is a way to fetch the panel rather than a
    /// drop-down handle, so it brings it to the front instead of hiding it — a
    /// panel somebody chose to keep on screen should not vanish because they
    /// touched the menu bar.
    func toggleDropDown() {
        guard home == .menuBar else {
            panel.orderFrontRegardless()
            return
        }
        if panel.isVisible {
            dismissDropDown()
        } else {
            positionUnderLamp()
            panel.orderFrontRegardless()
            panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismissDropDown() {
        guard home == .menuBar, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Moves the panel between its two homes, from the footer button or the menu.
    func toggleHome() {
        Diagnostics.log("toggleHome: \(home.rawValue) -> \(home.other.rawValue)")
        home = home.other
        preferences.home = home
        if home == .menuBar { preferences.showsMenuBarIcon = true }
        applyHome(showing: home == .floating)
        rebuildContent()
    }

    /// Shows or hides the lamp on its own, leaving the panel where it is.
    func toggleMenuBarIcon() {
        // Refused rather than obeyed when it would strand the panel: the switch
        // that would leave nothing able to open it is the one place this app
        // says no, and it says why.
        guard !(preferences.showsMenuBarIcon && home == .menuBar) else {
            Alerts.tell(
                title: "The lamp stays while the panel lives in the menu bar",
                message: "Nothing else could bring the panel back. Put the panel back "
                    + "in its own window first, and then the lamp can go."
            )
            return
        }
        preferences.showsMenuBarIcon.toggle()
        applyHome(showing: panel.isVisible || home == .floating)
        rebuildContent()
    }

    /// Puts the floating panel back where it lived.
    ///
    /// Without this the panel came back **exactly where the drop-down was** —
    /// hanging under the lamp, the same width, the same rows — and the only
    /// difference was that it no longer went away when you looked elsewhere.
    /// Reported as *the button doesn't work*, and that reading was right: a
    /// button that says it will bring the panel back to its own window has not
    /// done its job while the panel is still standing where the menu left it.
    ///
    /// The corner is the one `observePanelMoves` saved, which only ever records a
    /// position somebody chose, because it refuses to save a drop-down's. With no
    /// saved corner — a fresh install that went to the menu bar first — the
    /// default hangs it from the top right, which is where a new panel goes.
    private func returnToItsOwnCorner() {
        panel.setFrame(
            Preferences.placed(
                size: panel.frame.size,
                anchor: preferences.savedAnchor,
                on: panel.screen ?? NSScreen.main
            ),
            display: true
        )
        Diagnostics.log("panel back in its own corner at \(panel.frame)")
    }

    /// Hangs the panel under the lamp, kept whole on the screen it is on.
    ///
    /// Centred on the lamp and then pulled back inside the screen, because a lamp
    /// near the right-hand edge — which is where a newly added one lands, beside
    /// the clock — would otherwise hang half its panel off the display.
    func positionUnderLamp() {
        guard let button = lamp.anchorButton, let barWindow = button.window else { return }
        let onScreen = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(onScreen) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        var x = onScreen.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        // `visible.maxY` is already below the menu bar, so this hangs from the
        // bar itself with a hair of daylight, the way a menu does.
        let y = visible.maxY - size.height - 4
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        Diagnostics.log("drop-down hung at \(panel.frame) under lamp \(onScreen)")
    }

    /// What the lamp stands for, computed from the same rendering the column draws.
    var currentSummary: MenuBarSummary {
        MenuBarSummary.of(
            rendering: currentRendering,
            calmWorkspaces: preferences.calmBlinkWorkspaces
        )
    }

    // MARK: - The wiring

    /// Every switch the panel offers, bound to the thing that flips it.
    ///
    /// Here rather than beside the panel it belongs to, because it is a list and
    /// not a decision: `PanelController` had grown past the eight hundred lines
    /// this project holds itself to, and a list of closures is the part of it
    /// nobody reads to understand how the panel behaves.
    func makeActions() -> PanelActions {
        PanelActions(
            openExtended: { [weak self] in self?.openExtendedWindow() },
            openSettings: { [weak self] in self?.onOpenSettings?() },
            openLegend: { [weak self] in self?.onOpenLegend?() },
            toggleCompact: { [weak self] in self?.toggleCompact() },
            toggleHome: { [weak self] in self?.toggleHome() },
            toggleMenuBarIcon: { [weak self] in self?.toggleMenuBarIcon() },
            toggleSessionTab: { [weak self] in
                self?.preferences.opensSessionTab.toggle()
                self?.rebuildContent()
            },
            toggleOnlyWaiting: { [weak self] in
                self?.preferences.showsOnlyWaiting.toggle()
                self?.rebuildContent()
            },
            toggleNotifications: { [weak self] in self?.toggleNotifications() },
            toggleMessageSending: { [weak self] in self?.toggleMessageSending() },
            togglePresence: { [weak self] in self?.togglePresence() },
            toggleTerminalSessions: { [weak self] in self?.toggleTerminalSessions() },
            muteForAnHour: { [weak self] in
                self?.preferences.mutedUntil = Date().addingTimeInterval(3600)
                self?.rebuildContent()
            },
            clearMute: { [weak self] in
                self?.preferences.mutedUntil = nil
                self?.rebuildContent()
            },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            installHooks: { [weak self] in self?.installHooks() },
            uninstallHooks: { [weak self] in self?.uninstallHooks() },
            requestAccessibility: { VSCodeFocuser.requestAccessibilityPermission() },
            fixIssue: { PermissionRequest.offer($0) },
            showHiddenAgain: { [weak self] in
                self?.preferences.hiddenWorkspaces = []
                self?.rebuildContent()
            },
            clearSessions: { [weak self] in self?.store.reset() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            quit: { NSApp.terminate(nil) }
        )
    }
}
