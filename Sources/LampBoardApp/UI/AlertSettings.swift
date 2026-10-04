import LampBoardCore
import SwiftUI

extension Notification.Name {
    /// The menu bar counter was switched: the lamp draws its title again.
    static let menuBarCounterChanged = Notification.Name("com.lampboard.menuBarCounterChanged")
    /// The bar's shortcut from anywhere was chosen: it is registered again (D77).
    static let barShortcutChanged = Notification.Name("com.lampboard.barShortcutChanged")
}

/// The menu bar counter and the notification for a finished turn: two ways of
/// hearing more, both off until asked for (5.6).
struct AlertSettings: View {
    private let preferences = Preferences()
    @State private var counter = Preferences().menuBarCounter
    @State private var finished = Preferences().notifyFinished
    @State private var shortcut = Preferences().barShortcut

    var body: some View {
        Section {
            Toggle("Count in the menu bar: waiting · working", isOn: $counter)
                .onChange(of: counter) { _, value in
                    preferences.menuBarCounter = value
                    NotificationCenter.default.post(name: .menuBarCounterChanged, object: nil)
                }
            Text("""
            Beside the lamp, how many sessions want you — waiting for an answer, finished \
            with something to read, or failed — and how many are at work.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Also notify when a turn finishes", isOn: $finished)
                .onChange(of: finished) { _, value in preferences.notifyFinished = value }
            Text("""
            With notifications on, LampBoard tells you when a session waits for you and when \
            a turn fails, saying what it asks or why it stopped. This adds a notification for \
            every finished turn, with the first line of the answer.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("Search bar from any app", selection: $shortcut) {
                ForEach(BarShortcut.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: shortcut) { _, value in
                preferences.barShortcut = value
                NotificationCenter.default.post(name: .barShortcutChanged, object: nil)
            }
            Text("""
            Inside the panel, ⌘K opens the search bar. This brings the panel and the bar up             from any application. Off by default: ⌘K alone would take the shortcuts VS Code             begins with it.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Menu bar and notifications")
        }
    }
}
