import AppKit
import LampBoardCore
import SwiftUI

/// The Hub (D149): a window of columns, the last depth of ⌘⇧L where the Plancia
/// was. The sessions on the left are the panel's own rows; the conversation is
/// beside them; the files, the preview and the project's terminal come and go
/// with the toolbar's icons. Columns are an `NSSplitView`: the widths and what
/// is shown are kept by macOS between launches.
@MainActor
final class HubWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {

    let model: HubModel
    private let sidebarContent: (_ select: @escaping (String) -> Void) -> AnyView
    var onVisibilityChange: () -> Void = {}

    private var window: NSWindow?
    private var split: NSSplitViewController?
    private var sidebarHost: NSHostingController<HubSidebarView>?

    private static let sidebarItem = NSToolbarItem.Identifier("hub.sidebar")
    private static let sidebarCollapsedKey = "hubSidebarCollapsed"

    init(model: HubModel) {
        self.model = model
        self.sidebarContent = model.deps.sidebar
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Opens the Hub, on `session` when one is named.
    func show(session: String? = nil) {
        let window = self.window ?? makeWindow()
        if let session { model.selected = session }
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange()
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.performClose(nil) }

    /// The panel changed (an order, a name, a mute): the sidebar redraws as it does.
    func refreshSidebar() {
        guard let host = sidebarHost else { return }
        host.rootView = HubSidebarView(model: model, panel: sidebarContent { [weak self] id in self?.model.selected = id })
    }

    /// What the Hub shows, for the tests (fake home only).
    func report() -> Data? {
        let session = model.session
        let body: [String: Any] = [
            "open": isOpen,
            "selected": model.selected ?? NSNull(),
            "sessionsShown": !(split?.splitViewItems.first?.isCollapsed ?? true),
            "lampMasterRow": model.deps.lampMaster?.snapshot.enabled ?? false,
            "mode": model.mode.rawValue,
            "route": model.route.rawValue,
            "chatMessages": model.chat?.messages.count ?? 0,
            "status": session?.status.rawValue ?? NSNull(),
            "windowNumber": window?.windowNumber ?? 0,
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Building

    private func makeWindow() -> NSWindow {
        let sidebar = NSHostingController(rootView: HubSidebarView(model: model, panel: sidebarContent { [weak self] id in
            self?.model.selected = id
        }))
        sidebarHost = sidebar
        let conversation = NSHostingController(rootView: HubConversationView(model: model))

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey)
        let chatItem = NSSplitViewItem(viewController: conversation)
        chatItem.minimumThickness = 320
        chatItem.holdingPriority = .defaultLow
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(chatItem)
        split.splitView.autosaveName = "LampBoardHub.columns"
        split.splitView.identifier = NSUserInterfaceItemIdentifier("hub.split")
        self.split = split

        let window = NSWindow(contentViewController: split)
        window.title = "LampBoard"
        window.subtitle = "Hub"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("LampBoardHub")
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("hub.window")
        window.delegate = self
        let toolbar = NSToolbar(identifier: "LampBoardHub")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.window = window
        return window
    }

    // MARK: - Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.sidebarItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Sessions"
        item.toolTip = "Show or hide the sessions"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sessions")
        item.target = self
        item.action = #selector(toggleSessions)
        item.isBordered = true
        return item
    }

    @objc func toggleSessions() {
        guard let item = split?.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
        UserDefaults.standard.set(item.isCollapsed, forKey: Self.sidebarCollapsedKey)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange() }
    }
}
