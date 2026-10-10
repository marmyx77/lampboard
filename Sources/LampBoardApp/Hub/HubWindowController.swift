import AppKit
import Combine
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
    private var cancellables = Set<AnyCancellable>()

    private static let sidebarItem = NSToolbarItem.Identifier("hub.sidebar")
    private static let filesItem = NSToolbarItem.Identifier("hub.files")
    private static let previewItem = NSToolbarItem.Identifier("hub.preview")
    private static let terminalItem = NSToolbarItem.Identifier("hub.terminal")
    private static let sidebarCollapsedKey = "hubSidebarCollapsed"
    private static let filesShownKey = "hubFilesShown"

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
            "notice": model.notice ?? NSNull(),
            "followed": model.followed ?? NSNull(),
            "liveText": model.live?.text ?? NSNull(),
            "filesShown": !(split.map { $0.splitViewItems.count > 2 ? $0.splitViewItems[2].isCollapsed : true } ?? true),
            "lastShown": !(split.map { $0.splitViewItems.count > 3 ? $0.splitViewItems[3].isCollapsed : true } ?? true),
            "lastColumn": model.files.lastColumn.rawValue,
            "projectRoot": model.files.source?.root ?? NSNull(),
            "treeEntries": model.files.entries(in: nil).map { $0.isFolder ? $0.name + "/" : $0.name },
            "git": model.files.git,
            "marks": model.files.marks.mapValues(\.rawValue),
            "openFile": model.files.active ?? NSNull(),
            "openFileText": model.files.activeFile?.text.map { String($0.prefix(2000)) } ?? NSNull(),
            "openFilePreview": model.files.active.map { model.files.previews.contains($0) } ?? false,
            "searchHits": model.files.hits.map { "\($0.path):\($0.line)" },
            "shellRunning": model.files.source.map { model.shells.isRunning(root: $0.root, host: $0.host) } ?? false,
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Building

    private func makeWindow() -> NSWindow {
        let sidebar = NSHostingController(rootView: HubSidebarView(model: model, panel: sidebarContent { [weak self] id in
            self?.model.selected = id
        }))
        sidebarHost = sidebar
        // Dark whatever the Mac is, like the panel (StatusPalette.appearance).
        sidebar.view.appearance = StatusPalette.appearance
        let conversation = NSHostingController(rootView: HubConversationView(model: model))

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = Preferences.sharedDefaults.bool(forKey: Self.sidebarCollapsedKey)
        let chatItem = NSSplitViewItem(viewController: conversation)
        chatItem.minimumThickness = 320
        chatItem.holdingPriority = .defaultLow
        let filesItem = NSSplitViewItem(viewController: NSHostingController(rootView: HubFilesView(files: model.files)))
        filesItem.minimumThickness = 200
        filesItem.canCollapse = true
        filesItem.isCollapsed = !Preferences.sharedDefaults.bool(forKey: Self.filesShownKey)
        let lastItem = NSSplitViewItem(viewController: NSHostingController(rootView: HubLastColumnView(files: model.files, shells: model.shells)))
        lastItem.minimumThickness = 260
        lastItem.canCollapse = true
        lastItem.isCollapsed = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(chatItem)
        split.addSplitViewItem(filesItem)
        split.addSplitViewItem(lastItem)
        // Opening a file shows the last column, as the Claude app does.
        model.files.$active.dropFirst().sink { [weak self] active in
            guard active != nil else { return }
            self?.setLast(.file, shown: true)
        }.store(in: &cancellables)
        // A fake home keeps its widths apart from the person's (Preferences.sharedDefaults' rule).
        split.splitView.autosaveName = AppConfig.isUsingHomeOverride ? "LampBoardHub.columns.test" : "LampBoardHub.columns"
        split.splitView.identifier = NSUserInterfaceItemIdentifier("hub.split")
        self.split = split

        let window = NSWindow(contentViewController: split)
        window.title = "LampBoard"
        window.subtitle = "Hub"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName(AppConfig.isUsingHomeOverride ? "LampBoardHub.test" : "LampBoardHub")
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
        [Self.sidebarItem, .flexibleSpace, Self.filesItem, Self.previewItem, Self.terminalItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, .flexibleSpace, Self.filesItem, Self.previewItem, Self.terminalItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let spec: (String, String, String, Selector)
        switch id {
        case Self.sidebarItem: spec = ("Sessions", "Show or hide the sessions", "sidebar.left", #selector(toggleSessions))
        case Self.filesItem: spec = ("Files", "Show or hide the project's files", "folder", #selector(toggleFiles))
        case Self.previewItem: spec = ("Preview", "Show or hide the open file", "doc.text", #selector(togglePreview))
        case Self.terminalItem: spec = ("Terminal", "A shell in the project's folder", "apple.terminal", #selector(toggleTerminal))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.0
        item.toolTip = spec.1
        item.image = NSImage(systemSymbolName: spec.2, accessibilityDescription: spec.0)
        item.target = self
        item.action = spec.3
        item.isBordered = true
        return item
    }

    @objc func toggleFiles() {
        guard let items = split?.splitViewItems, items.count > 2 else { return }
        items[2].animator().isCollapsed.toggle()
        Preferences.sharedDefaults.set(!items[2].isCollapsed, forKey: Self.filesShownKey)
    }

    @objc func togglePreview() { toggleLast(.file) }
    @objc func toggleTerminal() { toggleLast(.terminal) }

    /// The last column shows a file or the shell: its icon shows it, the same
    /// icon again hides it, the other icon switches it.
    private func toggleLast(_ what: HubFilesModel.LastColumn) {
        guard let items = split?.splitViewItems, items.count > 3 else { return }
        let showing = !items[3].isCollapsed && model.files.lastColumn == what
        setLast(what, shown: !showing)
    }

    func setLast(_ what: HubFilesModel.LastColumn, shown: Bool) {
        guard let items = split?.splitViewItems, items.count > 3 else { return }
        model.files.lastColumn = what
        if items[3].isCollapsed == shown { items[3].animator().isCollapsed = !shown }
    }

    /// `POST /hub/files` (fake home only): `{"files", "last", "open", "query", "preview"}`.
    func applyTest(_ body: Data) -> Bool {
        guard let wish = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        setColumns(files: wish["files"] as? Bool, last: (wish["last"] as? String).flatMap(HubFilesModel.LastColumn.init(rawValue:)))
        if let folder = wish["expand"] as? String { model.files.toggle(folder) }
        if let path = wish["open"] as? String { model.files.openFile(path) }
        if let query = wish["query"] as? String { model.files.query = query }
        if wish["stop"] as? Bool == true { model.stop() }
        if let preview = wish["preview"] as? Bool, let active = model.files.active {
            if preview { model.files.previews.insert(active) } else { model.files.previews.remove(active) }
        }
        return true
    }

    /// The tests' wish for the columns (fake home only): files, and a file or the shell.
    func setColumns(files: Bool?, last: HubFilesModel.LastColumn?) {
        if let files, let items = split?.splitViewItems, items.count > 2, items[2].isCollapsed == files { toggleFiles() }
        if let last { setLast(last, shown: true) }
    }

    @objc func toggleSessions() {
        guard let item = split?.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
        Preferences.sharedDefaults.set(item.isCollapsed, forKey: Self.sidebarCollapsedKey)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange() }
    }
}
