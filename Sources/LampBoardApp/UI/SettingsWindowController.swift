import AppKit
import SwiftUI

/// Owns the Settings window.
///
/// An ordinary titled window, like the extended one and for the same reason: you
/// type into it, you read outcomes in it, you want it in ⌘-tab. The panel stays
/// what it is — a column that never takes focus — and this is where the
/// configuration that does not fit a context menu goes. Today that is the remote
/// machines; the form is built so the next setting has a place.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let fleet: RemoteFleet
    private let lampMaster: LampMasterService

    init(fleet: RemoteFleet, lampMaster: LampMasterService) {
        self.fleet = fleet
        self.lampMaster = lampMaster
    }

    func show() {
        if let window {
            bringToFront(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "lampboard Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(fleet: fleet, lampMaster: lampMaster))
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
    }
}
