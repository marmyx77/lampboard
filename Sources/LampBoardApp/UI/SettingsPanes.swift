import AppKit
import LampBoardCore
import SwiftUI

extension Notification.Name {
    /// The menu bar counter was switched: the lamp draws its title again.
    static let menuBarCounterChanged = Notification.Name("com.lampboard.menuBarCounterChanged")
    /// The bar's shortcut from anywhere was chosen: it is registered again (D77).
    static let barShortcutChanged = Notification.Name("com.lampboard.barShortcutChanged")
}

// The sections of the Settings window (U3). Each one draws the settings
// `SettingsCatalog` lists for it, in that order, with the names and lines it
// gives them; what a switch does is the panel's own action wherever it has one.

private func groupTitle(_ id: SettingsCatalog.ID) -> String {
    SettingsCatalog.section(of: id).groups.first { $0.items.contains { $0.id == id } }?.title ?? ""
}

struct PanelPane: View {
    @ObservedObject var model: SettingsModel
    private let preferences = Preferences()

    var body: some View {
        if let flags = model.flags {
            SettingsGroupBox(title: groupTitle(.home)) {
                SettingRow(id: .home) {
                    Picker("", selection: Binding(get: { flags.home }, set: { wanted in
                        if wanted != flags.home { model.run { $0.toggleHome() } }
                    })) {
                        Text("Floating window").tag(PanelHome.floating)
                        Text("Menu bar").tag(PanelHome.menuBar)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingToggle(id: .lampInMenuBar, isOn: flags.showsMenuBarIcon, enabled: flags.home != .menuBar) { _ in
                    model.run { $0.toggleMenuBarIcon() }
                }
                SettingToggle(id: .menuBarCounter, isOn: preferences.menuBarCounter) { value in
                    preferences.menuBarCounter = value
                    NotificationCenter.default.post(name: .menuBarCounterChanged, object: nil)
                    model.refresh()
                }
            }
            SettingsGroupBox(title: groupTitle(.width)) {
                SettingRow(id: .width) {
                    Picker("", selection: Binding(get: { flags.compact }, set: { wanted in
                        if wanted != flags.compact { model.run { $0.toggleCompact() } }
                    })) {
                        Text("Full").tag(false)
                        Text("Lights only").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingToggle(id: .onlyWaiting, isOn: flags.onlyWaiting) { _ in model.run { $0.toggleOnlyWaiting() } }
                SettingToggle(id: .terminalSessions, isOn: flags.showsTerminalSessions) { _ in
                    model.run { $0.toggleTerminalSessions() }
                }
                SettingRow(id: .hiddenProjects) {
                    Button(flags.hiddenCount == 0 ? "None hidden" : "Show \(flags.hiddenCount) again") {
                        model.run { $0.showHiddenAgain() }
                    }
                    .disabled(flags.hiddenCount == 0)
                }
            }
            SettingsGroupBox(title: groupTitle(.launchAtLogin)) {
                if flags.canLaunchAtLogin {
                    SettingToggle(id: .launchAtLogin, isOn: flags.launchesAtLogin) { _ in
                        model.run { $0.toggleLaunchAtLogin() }
                    }
                } else {
                    SettingRow(id: .launchAtLogin) { Text("From the installed app").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct ClicksPane: View {
    @ObservedObject var model: SettingsModel
    private let preferences = Preferences()

    var body: some View {
        if let flags = model.flags {
            SettingsGroupBox(title: "") {
                SettingRow(id: .accessibility) {
                    if VSCodeFocuser.hasAccessibilityPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") { model.run { $0.requestAccessibility() } }
                    }
                }
                SettingToggle(id: .sessionTab, isOn: flags.opensSessionTab) { _ in model.run { $0.toggleSessionTab() } }
                SettingRow(id: .barShortcut) {
                    Picker("", selection: Binding(get: { preferences.barShortcut }, set: { value in
                        preferences.barShortcut = value
                        NotificationCenter.default.post(name: .barShortcutChanged, object: nil)
                        model.refresh()
                    })) {
                        ForEach(BarShortcut.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
}

struct AlertsPane: View {
    @ObservedObject var model: SettingsModel
    private let preferences = Preferences()

    var body: some View {
        if let flags = model.flags {
            SettingsGroupBox(title: groupTitle(.notifications)) {
                SettingToggle(id: .notifications, isOn: flags.notificationsEnabled) { _ in
                    model.run { $0.toggleNotifications() }
                }
                SettingToggle(id: .notifyFinished, isOn: preferences.notifyFinished, enabled: flags.notificationsEnabled) {
                    preferences.notifyFinished = $0
                    model.refresh()
                }
                SettingToggle(id: .speak, isOn: preferences.speakWaiting, enabled: flags.notificationsEnabled) {
                    preferences.speakWaiting = $0
                    model.refresh()
                }
            }
            SettingsGroupBox(title: groupTitle(.mute)) {
                SettingRow(id: .mute) {
                    if let until = flags.mutedUntil {
                        Button("Resume (muted until \(until.formatted(date: .omitted, time: .shortened)))") {
                            model.run { $0.clearMute() }
                        }
                    } else {
                        Button("For 1 hour") { model.run { $0.muteForAnHour() } }
                    }
                }
                SettingToggle(id: .away, isOn: flags.isAway) { _ in model.run { $0.toggleAway() } }
                SilencedProjects(model: model)
            }
            SettingsGroupBox(title: groupTitle(.presence)) {
                SettingToggle(id: .presence, isOn: flags.presenceEnabled) { _ in model.run { $0.togglePresence() } }
            }
        }
    }
}

/// The projects a row's Quiet menu silenced, each with the way back.
private struct SilencedProjects: View {
    @ObservedObject var model: SettingsModel
    private let preferences = Preferences()

    var body: some View {
        let muted = preferences.mutedWorkspaces.sorted()
        let calm = preferences.calmBlinkWorkspaces.sorted()
        SettingRow(id: .silenced) {
            if muted.isEmpty && calm.isEmpty { Text("None").foregroundStyle(.secondary) }
        }
        ForEach(muted, id: \.self) { path in
            line(path, "no alerts", "Alert again") {
                preferences.mutedWorkspaces = preferences.mutedWorkspaces.subtracting([path])
            }
        }
        ForEach(calm, id: \.self) { path in
            line(path, "no blinking", "Blink again") {
                preferences.calmBlinkWorkspaces = preferences.calmBlinkWorkspaces.subtracting([path])
            }
        }
    }

    private func line(_ path: String, _ what: String, _ undo: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            Text((path as NSString).lastPathComponent).font(.callout.weight(.medium))
            Text(what).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(undo) { action(); model.redraw() }
        }
        .padding(.leading, 12)
    }
}

struct AgentsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let flags = model.flags {
            SettingsGroupBox(title: groupTitle(.connection)) {
                SettingRow(id: .connection) {
                    if flags.hooksInstalled {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Disconnect…") { model.run { $0.uninstallHooks() } }
                        }
                    } else {
                        Button(flags.hooksMissingFrom.isEmpty
                               ? "Connect…" : "Connect \(flags.hooksMissingFrom.joined(separator: " and "))…") {
                            model.run { $0.installHooks() }
                        }
                    }
                }
            }
            SettingsGroupBox(title: groupTitle(.helper)) {
                ModSettings()
                SettingToggle(id: .band, isOn: Preferences().bandEnabled) { value in
                    Preferences().bandEnabled = value
                    model.refresh()
                }
            }
        }
    }
}

struct ActingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let flags = model.flags {
            SettingsGroupBox(title: groupTitle(.sendMessages), warns: true) {
                SettingToggle(id: .sendMessages, isOn: flags.messageSendingEnabled) { _ in
                    model.run { $0.toggleMessageSending() }
                }
                let permissions = Preferences().permissionsFromPanel
                SettingToggle(id: .answerPrompts, isOn: permissions, enabled: ModSetup.isInstalled || permissions) { value in
                    Preferences().permissionsFromPanel = value
                    model.refresh()
                }
                SettingToggle(id: .safetyCatch, isOn: Preferences().safetyCatch) { value in
                    Preferences().safetyCatch = value
                    model.refresh()
                }
            }
        }
    }
}

struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let flags = model.flags {
            SettingsGroupBox(title: groupTitle(.usage)) {
                SettingToggle(id: .usage, isOn: flags.usageEnabled) { _ in model.run { $0.toggleUsage() } }
                SettingRow(id: .updates) { Text("Only when you ask").foregroundStyle(.secondary) }
            }
            SettingsGroupBox(title: groupTitle(.searchIndex)) {
                SettingToggle(id: .searchIndex, isOn: Preferences().searchIndexed) { value in
                    Preferences().searchIndexed = value
                    model.refresh()
                }
            }
        }
    }
}

struct AboutPane: View {
    @ObservedObject var model: SettingsModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    var body: some View {
        SettingsGroupBox(title: "") {
            SettingRow(id: .version) {
                HStack {
                    Text(version).foregroundStyle(.secondary)
                    Button("Check for updates…") { model.run { $0.checkForUpdates() } }
                }
            }
            SettingRow(id: .gettingStarted) {
                Button("Open…") { WelcomeWindowController.shared.show() }
            }
            SettingRow(id: .capabilities) {
                Button("Open…") { CapabilitiesWindowController.shared.show() }
            }
            SettingRow(id: .samples) {
                Button("Start") { model.startSamples() }
            }
            SettingRow(id: .legend) { Button("Open…") { model.run { $0.openLegend() } } }
            SettingRow(id: .clearList) { Button("Clear…") { model.run { $0.clearSessions() } } }
        }
    }
}
