import AppKit
import LampBoardCore
import SwiftUI

/// Owns the extended window — the one with the list on the left.
///
/// **One window, opened on request.** The panel remains the resting state: a
/// column of traffic lights that never takes focus. This is what you open when
/// you want to read and answer, and closing it puts you back to just the lights.
///
/// It is an ordinary `NSWindow` and not a `FloatingPanel`, for the same reason as
/// before: the panel must never steal focus because it sits beside the editor you
/// are typing in, and this window is the opposite — you scroll it, you select out
/// of it, you type into it, you want it in ⌘-tab.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var shell: ChatShell?

    private let store: StateStore
    private let preferences: Preferences
    private lazy var mailbox = MailboxWriter { [preferences] in preferences.messageSendingEnabled }
    private let raiseInEditor: (SessionState) -> Void

    init(
        store: StateStore,
        preferences: Preferences,
        raiseInEditor: @escaping (SessionState) -> Void
    ) {
        self.store = store
        self.preferences = preferences
        self.raiseInEditor = raiseInEditor
    }

    var isOpen: Bool { window?.isVisible == true }

    // MARK: - Opening

    /// Opens the window, optionally on a given conversation.
    ///
    /// Called again while open it just selects and comes forward, which is what
    /// makes ⌘+click on a row and `lampboard chat <n>` feel like switching tabs
    /// rather than opening things.
    func show(selecting sessionId: String? = nil) {
        if let window, let shell {
            if let sessionId { shell.select(sessionId) }
            bringToFront(window)
            return
        }

        let shell = ChatShell(store: store, preferences: preferences, mailbox: mailbox)
        let view = ChatShellView(shell: shell) { [weak self] session in
            self?.raiseInEditor(session)
        }

        let window = makeWindow()
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self

        self.window = window
        self.shell = shell

        shell.start(selecting: sessionId)
        bringToFront(window)
    }

    func close() {
        window?.close()
    }

    /// Clears anything a previous run left behind.
    ///
    /// Called once at startup, when the window cannot be open — so every marker on
    /// disk belongs to a dead process, and every listener still waiting on one is
    /// holding a process for a window that no longer exists.
    func reapStaleMailboxes() {
        let cleared = mailbox.reapStale()
        if cleared > 0 {
            Diagnostics.log("mailbox: cleared \(cleared) conversations left by a previous run")
        }
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LampBoard"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("lampboard-extended")
        if window.frame.origin == .zero { window.center() }
        return window
    }

    /// The app is an accessory (`LSUIElement`), so its windows do not come forward
    /// on their own. This is the one place lampboard takes focus, and it is
    /// legitimate: the user asked for a window, which is not the same as the panel
    /// grabbing focus while they are typing somewhere else.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        shell?.stop()
        shell = nil
        window = nil
    }

    /// Coming forward is reading: the unread badge clears here rather than on a
    /// timer, because "seen" means somebody looked.
    func windowDidBecomeKey(_ notification: Notification) {
        shell?.selected?.markRead()
    }
}
