import AppKit
import Combine
import LampBoardCore
import SwiftUI

/// «What LampBoard can do» (U5): every capability in a sentence, grouped by what
/// a person wants, with whether it needs the helper and whether it is on, and
/// two buttons — *Try*, which does the gesture in the real panel, and *Turn on*,
/// which opens the switch in Settings (installing the helper first when it is the
/// helper's). Opened from the panel's ⋯ and from Settings › About & help.
@MainActor
final class CapabilitiesWindowController: NSObject, NSWindowDelegate {

    static let shared = CapabilitiesWindowController()

    private var window: NSWindow?
    private var panel: () -> PanelController? = { nil }
    private var openSettings: (SettingsCatalog.ID) -> Void = { _ in }

    func configure(panel: @escaping () -> PanelController?, openSettings: @escaping (SettingsCatalog.ID) -> Void) {
        self.panel = panel
        self.openSettings = openSettings
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "What LampBoard can do"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CapabilitiesView(
            perform: { [weak self] action in self?.perform(action) }
        ))
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    enum Action {
        case tryIt(Capabilities.TryIt)
        case turnOn(Capabilities.Item)
    }

    private func perform(_ action: Action) {
        switch action {
        case .tryIt(let gesture):
            guard let panel = panel() else { return }
            switch gesture {
            case .bar(let text): panel.openBar(typing: text)
            case .samples: panel.startSamples()
            case .legend: panel.onOpenLegend?()
            }
        case .turnOn(let item):
            guard let setting = item.setting else { return }
            if item.needsHelper && !ModSetup.isInstalled {
                Task {
                    // Settings opens on a switch that needs the helper only once
                    // the helper is there; a failure is said, not swallowed.
                    if case .failed(let reason) = await Task.detached(operation: { ModSetup.install() }).value {
                        Alerts.warn(title: "The helper could not be installed", message: reason)
                        return
                    }
                    openSettings(setting)
                }
            } else {
                openSettings(setting)
            }
        }
    }
}

private struct CapabilitiesView: View {
    let perform: (CapabilitiesWindowController.Action) -> Void
    /// Read every few seconds: *Turn on…* or Settings can install the helper
    /// while this window is open.
    @State private var helper = ModSetup.isInstalled
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Everything here works on your own sessions. What needs the helper — a small Claude Code plugin that talks only to this Mac — says so, and Turn on installs it first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Capabilities.groups, id: \.title) { group in
                    SettingsGroupBox(title: group.title) {
                        ForEach(group.items, id: \.name) { item in
                            row(item)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onReceive(refresh) { _ in helper = ModSetup.isInstalled }
    }

    private func row(_ item: Capabilities.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name).font(.body.weight(.medium))
                Text(item.needsHelper ? (helper ? "helper installed" : "needs the helper") : "built in")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(item.needsHelper && !helper ? Color.orange.opacity(0.18) : Color.primary.opacity(0.07)))
                Spacer()
                if let gesture = item.tryIt {
                    Button("Try") { perform(.tryIt(gesture)) }
                }
                if item.setting != nil {
                    Button("Turn on…") { perform(.turnOn(item)) }
                }
            }
            Text(item.sentence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !item.place.isEmpty {
                Text(item.place).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
