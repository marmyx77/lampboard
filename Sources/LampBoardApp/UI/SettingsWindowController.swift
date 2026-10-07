import AppKit
import LampBoardCore
import SwiftUI

/// Owns the Settings window: nine sections down the side, one at a time on the
/// right, every setting with a line saying what it does (U3).
///
/// An ordinary titled window, like the extended one and for the same reason: you
/// type into it, you read outcomes in it, you want it in ⌘-tab. The panel stays
/// what it is — a column that never takes focus — and since 1.1 this is the one
/// place every switch lives; the menus keep only the things of every day.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let fleet: RemoteFleet
    private let lampMaster: LampMasterService
    private let model: SettingsModel

    init(fleet: RemoteFleet, lampMaster: LampMasterService, panel: @escaping () -> PanelController?) {
        self.fleet = fleet
        self.lampMaster = lampMaster
        self.model = SettingsModel(panel: panel)
    }

    /// - Parameter section: the section to open on, by title; the last one
    ///   looked at otherwise.
    func show(section: String? = nil) {
        if let section, let match = SettingsCatalog.sections.first(where: { $0.title.lowercased() == section.lowercased() }) {
            model.section = match.title
        }
        model.start()
        if let window {
            bringToFront(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LampBoard Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.contentView = NSHostingView(rootView: SettingsView(model: model, fleet: fleet, lampMaster: lampMaster))
        window.delegate = self
        window.center()

        self.window = window
        bringToFront(window)
    }

    func close() {
        window?.close()
    }

    /// An accessory app has to activate itself, or the window comes up behind the
    /// editor the user was just looking at.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.stop()
    }
}

/// What the Settings window reads of the panel, and the panel's own actions.
///
/// The switches that change how the panel looks or behaves already have their
/// actions on the panel — with the dialogs some of them need first, like sending
/// messages — so Settings calls the same ones rather than writing preferences
/// behind the panel's back. The panel can also change underneath it (a row's menu,
/// the lamp's), so it is read again every second while the window is open.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var flags: PanelFlags?
    @Published var section = SettingsCatalog.sections[0].title
    private let panel: () -> PanelController?
    private var timer: Timer?

    init(panel: @escaping () -> PanelController?) {
        self.panel = panel
    }

    /// Reads the panel now and every second, while the window is open only.
    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Publishes every second even when nothing changed, on purpose: the panes
    /// also read preferences no flag carries (the band, the safety catch, the
    /// index), and another window can change those while this one is open.
    func refresh() { flags = panel()?.panelFlags }

    /// Runs one of the panel's actions, then reads the panel again.
    func run(_ action: (PanelActions) -> Void) {
        guard let actions = panel()?.makeActions() else { return }
        action(actions)
        refresh()
    }

    /// For the preferences the panel draws from without an action of its own.
    func redraw() {
        panel()?.rebuildContent()
        refresh()
    }
}
