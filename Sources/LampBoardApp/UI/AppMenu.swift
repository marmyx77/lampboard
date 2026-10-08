import AppKit

/// The menus a Mac routes its keys through (D138).
///
/// An accessory app shows no menu bar, and nothing had given LampBoard a main
/// menu at all, so ⌘C, ⌘V and ⌘A reached no one: AppKit sends a key equivalent
/// to the main menu, and the menu's item sends `copy:` or `paste:` to whatever
/// has the keys. In the live view the paste simply did not happen. The menu is
/// installed whatever the activation policy: hidden while LampBoard is an
/// accessory, it still routes the keys, and it is the menu bar while a live
/// window gives LampBoard a place in the Dock.
@MainActor
enum AppMenu {

    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "LampBoard")
        // No ⌘Q: a key pressed for another app must not quit the one holding the
        // lamps. Quitting stays in the panel's ⋯ and here, by click.
        app.addItem(withTitle: "Hide LampBoard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit LampBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        main.addItem(submenu(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window))

        NSApp.mainMenu = main
        // macOS lists the open windows here by itself.
        NSApp.windowsMenu = window
    }

    /// The key equivalents the menu holds, for `GET /live` under a fake home.
    static var keys: [String] {
        (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.map(\.keyEquivalent).filter { !$0.isEmpty }
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
