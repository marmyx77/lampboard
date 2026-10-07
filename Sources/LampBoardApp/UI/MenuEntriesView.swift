import AppKit
import LampBoardCore
import SwiftUI

/// Draws a menu built in Core (`Menus`, U3) as SwiftUI context-menu content.
///
/// The words, the order and what is offered are decided there, where a test can
/// count them; this only turns each entry into a button, a divider or a submenu,
/// and hands the chosen command back.
struct MenuEntriesView: View {
    let entries: [MenuEntry]
    let perform: (MenuCommand) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .item(let command, let title, let checked, let enabled, let shortcut):
                // SwiftUI offers no Toggle inside a context menu that looks right
                // here: a switch is a check mark before its name.
                let button = Button(checked ? "✓ \(title)" : title) { perform(command) }.disabled(!enabled)
                if let shortcut, let key = shortcut.first {
                    button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                } else {
                    button
                }
            case .divider:
                Divider()
            case .submenu(let title, let inner):
                Menu(title) { AnyView(MenuEntriesView(entries: inner, perform: perform)) }
            case .heading(let title):
                Text(title)
            }
        }
    }
}

extension NSMenu {
    /// The same entries as an AppKit menu, for the lamp in the menu bar, whose
    /// menu is an `NSMenu` popped up under its button. `targets` keeps the
    /// closures alive: an `NSMenuItem` holds its target weakly.
    static func from(_ entries: [MenuEntry], targets: inout [MenuAction], perform: @escaping (MenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .item(let command, let title, let checked, let enabled, let shortcut):
                let target = MenuAction { perform(command) }
                targets.append(target)
                let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: shortcut ?? "")
                item.target = target
                item.isEnabled = enabled
                item.state = checked ? .on : .off
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            case .submenu(let title, let inner):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = from(inner, targets: &targets, perform: perform)
                menu.addItem(item)
            case .heading(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        return menu
    }
}
