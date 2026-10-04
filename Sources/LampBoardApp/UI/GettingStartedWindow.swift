import AppKit
import Combine
import LampBoardCore
import SwiftUI

/// "Getting started": the real setup, each item explained before its button,
/// and the first gestures worth trying on one's own sessions.
///
/// A window and not a list in the panel, for the reason LampMaster's cards are
/// one (D61): the panel's height is a formula, and text of any length takes its
/// room from the last rows. Opened after the hooks are installed, and from both
/// menus.
@MainActor
final class GettingStartedWindowController: NSObject, NSWindowDelegate {

    static let shared = GettingStartedWindowController()

    private var window: NSWindow?
    private(set) var port = AppConfig.listenPort
    private(set) var lampMaster: LampMasterService?
    private(set) var toggleNotifications: () -> Void = {}

    /// Set once at launch by whoever owns the server and the panel.
    func configure(port: UInt16, lampMaster: LampMasterService, toggleNotifications: @escaping () -> Void) {
        self.port = port
        self.lampMaster = lampMaster
        self.toggleNotifications = toggleNotifications
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Getting started with LampBoard"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GettingStartedView(controller: self))
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// What the Mac shows today, read fresh: a tick is done where it was done.
    func facts() -> GettingStarted.Facts {
        let preferences = Preferences()
        let files = LampMasterFiles()
        var facts = GettingStarted.Facts()
        facts.hooks = HookSetup.state().contains { $0.outcome == .installed }
        facts.accessibility = AXIsProcessTrusted()
        facts.notifications = preferences.notificationsEnabled
        facts.lampMaster = preferences.lampMasterEnabled
        facts.lampMasterCallable = LampMasterSetup.isRegistered
        facts.tourFinished = (UserDefaults(suiteName: TourController.domain)?.data(forKey: "progress"))
            .flatMap { try? JSONDecoder().decode(TourProgress.self, from: $0) }?.status == .finished
        facts.renamed = !preferences.rowNames.isEmpty
        facts.reordered = !preferences.rowOrder.isEmpty
        let answered: Set<LampMasterShown.Outcome> = [.accepted, .ignored, .muted, .wrong]
        facts.answeredLampMaster = files.suggestions().contains { $0.outcome.map(answered.contains) == true }
        facts.askedFromSession = !files.asks().isEmpty
        return facts
    }

    /// The button of an item, when it has one.
    func act(on id: String) async -> String? {
        switch id {
        case "hooks":
            let reports = HookSetup.install(port: port)
            return HookSetup.hasFailure(in: reports) ? HookSetup.summary(of: reports) : nil
        case "accessibility":
            VSCodeFocuser.requestAccessibilityPermission()
        case "notifications":
            toggleNotifications()
        case "lampmaster":
            lampMaster?.setEnabled(true)
        case "callable":
            let port = port
            if case .failed(let reason) = await Task.detached(operation: { LampMasterSetup.register(port: port) }).value {
                return reason
            }
        case "tour":
            TrialLauncher.startFromMenu()
        default:
            break
        }
        return nil
    }
}

struct GettingStartedView: View {
    let controller: GettingStartedWindowController
    @State private var facts = GettingStarted.Facts()
    @State private var problem: String?
    /// The permission arrives from System Settings, not from a click here: the
    /// list is read again every couple of seconds while it is open.
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("LampBoard tells you which of your sessions is waiting for you, and takes you there in one click.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                section("Set up", GettingStarted.preparation(facts), actions: true)
                section("First steps with your own sessions", GettingStarted.firstSteps(facts), actions: false)
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                let left = GettingStarted.remaining(facts)
                Text(left == 0 ? "All set. The optional ones are there whenever you want them."
                               : "\(left) left. Each one ticks itself when it is done, wherever you do it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { facts = controller.facts() }
        .onReceive(refresh) { _ in facts = controller.facts() }
    }

    private static let verb = ["hooks": "Install", "accessibility": "Grant…", "tour": "Start"]

    private func section(_ title: String, _ items: [GettingStarted.Item], actions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? StatusPalette.lampMasterTint : Color.secondary)
                        .accessibilityLabel(item.done ? "Done" : "Not done")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.title).fontWeight(.medium)
                            if item.optional { Text("optional").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(item.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if actions, !item.done {
                        Button(Self.verb[item.id] ?? "Turn on") {
                            Task {
                                problem = await controller.act(on: item.id)
                                facts = controller.facts()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
