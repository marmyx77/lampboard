import AppKit
import LampBoardCore
import SwiftUI

/// The first minute with LampBoard (U4): seven screens on the person's own
/// sessions, each with one idea and one button that does what is still missing
/// (`Welcome`). Opened at the first launch, always — in 1.0 the setup opened only
/// when the hooks were installed from the first alert's button, and the README
/// sent people to the terminal instead —, and again from Settings › About & help.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {

    static let shared = WelcomeWindowController()

    private var window: NSWindow?
    private let model = WelcomeModel()

    /// Set once at launch by whoever owns the server and the panel.
    func configure(port: UInt16, panel: @escaping () -> PanelController?) {
        model.port = port
        model.panel = panel
    }

    /// - Parameter step: the screen to open on; without one, the first when
    ///   the window opens, and wherever the person is when it is already open.
    func show(step: Welcome.Step? = nil) {
        if let step { model.step = step } else if window == nil { model.step = .welcome }
        model.start()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "Welcome to LampBoard"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(model: model, close: { [weak window] in window?.close() }))
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.stop()
    }
}

/// What the screens read of this Mac, again every second while the window is
/// open: a session that speaks, a permission granted in System Settings, the
/// helper installed elsewhere — each moves its screen on to *Next*.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published var step: Welcome.Step = .welcome
    @Published private(set) var facts = Welcome.Facts(connected: false, codexPresent: false, hasRow: false,
                                                       accessibility: false, helperInstalled: false, alertsOn: false)
    @Published private(set) var problem: String?
    @Published private(set) var working = false
    var port = AppConfig.listenPort
    var panel: () -> PanelController? = { nil }
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let agents = HookSetup.state()
        let panel = panel()
        facts = Welcome.Facts(
            connected: agents.contains { $0.outcome == .installed },
            codexPresent: agents.contains { $0.harness == .codex && $0.outcome != .notPresent },
            hasRow: !(panel?.store.state.sessions.isEmpty ?? true) || panel?.samples.isOn == true,
            accessibility: AXIsProcessTrusted(),
            helperInstalled: ModSetup.isInstalled,
            alertsOn: Preferences().notificationsEnabled
        )
    }

    var lampStatus: SessionStatus? {
        guard let panel = panel() else { return nil }
        let rows = ColumnLayout.render(panel.store.state.adding(panel.samples.sessions()), options: panel.columnOptions).rows
        return rows.first?.status
    }

    func perform(_ action: Welcome.Action, close: () -> Void) {
        problem = nil
        switch action {
        case .next:
            if let next = Welcome.Step(rawValue: step.rawValue + 1) { step = next }
        case .connect:
            let reports = HookSetup.install(port: port)
            if HookSetup.hasFailure(in: reports) { problem = HookSetup.summary(of: reports) }
            panel()?.rebuildContent()
        case .practice:
            panel()?.startSamples()
        case .grantAccessibility:
            VSCodeFocuser.requestAccessibilityPermission()
        case .installHelper:
            working = true
            Task {
                let outcome = await Task.detached { ModSetup.install() }.value
                if case .failed(let reason) = outcome { problem = reason } else {
                    // This screen is the one that asked to answer from here.
                    Preferences().permissionsFromPanel = true
                }
                working = false
                refresh()
            }
        case .turnOnAlerts:
            if !Preferences().notificationsEnabled { panel()?.toggleNotifications() }
        case .close:
            close()
        }
        refresh()
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let close: () -> Void

    var body: some View {
        let step = model.step
        let action = step.action(model.facts)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                ForEach(Welcome.Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 22, height: 4)
                }
                Spacer()
                Text("\(step.rawValue + 1) of \(Welcome.Step.allCases.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text(step.title).font(.title2.weight(.semibold))
            Text(step.text).font(.body).fixedSize(horizontal: false, vertical: true)
            illustration(step)
            Spacer(minLength: 0)
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if step != .welcome {
                    Button("Back") { if let back = Welcome.Step(rawValue: step.rawValue - 1) { model.step = back } }
                }
                Spacer()
                if action != .next && action != .close && step != .done {
                    Button("Skip") { model.perform(.next, close: close) }
                }
                Button(title(action)) { model.perform(action, close: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working)
            }
        }
        .padding(24)
        .frame(width: 520, height: 330)
    }

    @ViewBuilder
    private func illustration(_ step: Welcome.Step) -> some View {
        switch step {
        case .welcome, .colours:
            HStack(spacing: 18) {
                ForEach([(SessionStatus.working, "working"), (.ready, "done, to read"), (.awaiting, "needs you")], id: \.1) { status, label in
                    HStack(spacing: 6) {
                        TrafficLightDot(status: status, calm: false, listening: false)
                        Text(label).font(.callout)
                    }
                }
            }
        case .firstLamp:
            HStack(spacing: 8) {
                if let status = model.lampStatus {
                    TrafficLightDot(status: status, calm: false, listening: false)
                    Text("A lamp is in the panel.").font(.callout)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: Layout.dotSize, height: Layout.dotSize)
                    Text("Waiting for the first session to speak…").font(.callout).foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }

    private func title(_ action: Welcome.Action) -> String {
        switch action {
        case .next: return "Next"
        case .connect(let words): return words
        case .practice: return "Practice with samples"
        case .grantAccessibility: return "Grant Accessibility…"
        case .installHelper: return model.working ? "Installing…" : "Install the helper"
        case .turnOnAlerts: return "Alert me when needed"
        case .close: return "Close"
        }
    }
}
