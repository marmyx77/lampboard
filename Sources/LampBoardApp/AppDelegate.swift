import AppKit
import LampBoardCore
import UserNotifications

/// App startup and shutdown.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let port: UInt16
    private let skipSetupPrompt: Bool

    /// No panel: server and periodic realignment only.
    ///
    /// It exists for the end-to-end tests, which have to run *this* binary — same
    /// server, same reducer, same parser — without depending on a graphical
    /// session. A test that rebuilds the app in miniature verifies the miniature.
    private let headless: Bool

    private let snapshots = SnapshotBox()
    private lazy var store = StateStore(snapshots: snapshots)
    private let installer = HookInstaller()
    private let preferences = Preferences()

    private var server: SignalServer?
    private var panelController: PanelController?
    /// The remote machines: their tunnels and their hooks. Started in every mode,
    /// because a hook from another machine is as welcome headless as with the panel.
    private lazy var fleet = RemoteFleet(preferences: preferences, localPort: port)
    private lazy var settingsWindow = SettingsWindowController(fleet: fleet)
    /// Built with the panel, because it counts what the panel is showing.
    private var legendWindow: LegendWindowController?
    private var notifier: SessionNotifier?
    private var presence: PresenceFile?

    init(port: UInt16, skipSetupPrompt: Bool = false, headless: Bool = false) {
        self.port = port
        self.skipSetupPrompt = skipSetupPrompt
        self.headless = headless
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.startSession()

        // Accessory: no Dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        startServer()

        if !headless {
            startInterface()
        }

        store.startPolling()
        fleet.start()

        if !headless && shouldPromptForInstallation {
            preferences.wasSetupPromptShown = true
            promptForInstallation()
        }
    }

    /// Everything that only makes sense with a user in front of it.
    private func startInterface() {
        let controller = PanelController(store: store, installer: installer)
        controller.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        let legend = LegendWindowController(
            store: store,
            rendering: { [weak controller] in controller?.currentRendering ?? .empty }
        )
        legendWindow = legend
        controller.onOpenLegend = { legend.show() }
        controller.show()
        panelController = controller

        startNotifier(for: controller)
        startPresence()
    }

    private func startNotifier(for controller: PanelController) {
        let notifier = SessionNotifier(
            store: store,
            preferences: preferences,
            onOpen: { [weak controller] session in controller?.activate(session: session) }
        )
        notifier.start(isPanelVisible: { [weak controller] in
            controller?.isPanelVisible ?? false
        })
        self.notifier = notifier

        // The bundle guard is **not** redundant with the ones inside
        // `SessionNotifier`: `UNUserNotificationCenter.current()` does not return
        // nil outside a bundle, it raises `NSInternalInconsistencyException`
        // ("bundleProxyForCurrentProcess is nil") and terminates the process.
        // Without this line, `swift run LampBoardApp` during development crashes
        // at startup before it even draws the panel. Verified, not deduced.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        // Flipping the switch is the moment the user asked for the feature, so it
        // is the right moment for the system prompt.
        controller.onNotificationToggle = { [weak self] enabled in
            guard enabled else { return }
            self?.notifier?.requestAuthorization { granted in
                guard !granted else { return }
                Alerts.warn(
                    title: "Notifications not authorized",
                    message: """
                    macOS did not grant permission to send notifications.

                    System Settings › Notifications › LampBoard.
                    """
                )
            }
        }
    }

    private func startPresence() {
        let presence = PresenceFile(preferences: preferences)
        presence.start()
        self.presence = presence
    }


    /// The offer appears exactly once: anyone who declines still has the entry in
    /// the context menu, and anyone launching the app at login doesn't want a
    /// dialog waiting for a click on every sign-in.
    private var shouldPromptForInstallation: Bool {
        // Every agent on this machine, not just Claude Code. Asked of the
        // Claude installer alone, a person with Codex installed and Claude
        // already registered was never offered the other half and never told it
        // was missing.
        !skipSetupPrompt && !preferences.wasSetupPromptShown && HookSetup.needsInstalling()
    }

    /// Starting the app while it is already running: show the panel.
    ///
    /// An accessory application has no Dock icon and no window of the kind macOS
    /// raises for you, so before this the gesture did nothing whatsoever — and
    /// the person making it is, by definition, somebody who cannot see the panel.
    /// Answering it is the one door that needs no lamp, no pointer aimed at
    /// twenty-two points of menu bar, and nothing learned in advance.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.summon()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopPolling()
        fleet.stop()
        server?.stop()
        // The presence file has to go: leaving it would say "I'm at the Mac"
        // forever, and the phone push notifications would never arrive again.
        presence?.stop()
        presence?.remove()
        panelController?.close()
    }

    // MARK: - Server

    private func startServer() {
        let token = TokenStore().loadOrCreate()
        if token == nil {
            Diagnostics.log("token unavailable: GET /sessions will stay closed")
        }

        let server = SignalServer(
            port: port,
            token: token,
            onSignal: { [store] signal in
                Task { @MainActor in store.handle(signal) }
            },
            onError: { [store] message in
                Task { @MainActor in store.reportError(message) }
            },
            onQuery: { [snapshots] in snapshots.current() },
            onNext: { [weak self] in
                // The route raises windows, so it has to run where the windows
                // live, while the server invokes it from its own queue.
                //
                // The crossing is **time-bounded**, not a `main.sync`. Today
                // nobody on the main queue waits for the server's queue, so a
                // `sync` wouldn't deadlock — but one future line would be enough
                // to make it, and the symptom would be a frozen panel with no
                // explanation. With a bounded wait, the worst case is a request
                // that answers "not now".
                Self.onMain(timeout: 2) { self?.panelController?.activateNextWaiting() }
            },
            onOpenSlot: { [weak self] slot in
                Self.onMain(timeout: 2) { self?.panelController?.activateSlot(slot) }
            },
            onNewInSlot: { [weak self] slot in
                Self.onMain(timeout: 2) { self?.panelController?.newConversationInSlot(slot) }
            },
            onChatInSlot: { [weak self] slot in
                Self.onMain(timeout: 2) { self?.panelController?.openChatInSlot(slot) }
            }
        )

        do {
            try server.start()
            self.server = server
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Diagnostics.log("server did not start: \(message)")
            guard !headless else { return }
            Alerts.warn(title: "lampboard cannot receive signals", message: message)
        }
    }

    // MARK: - First run

    /// Without registered hooks the panel would stay empty forever, and the user
    /// would have no way of working out why: better to say so straight away.
    private func promptForInstallation() {
        let agents = HookSetup.state()
            .filter { $0.outcome != .notPresent }
            .map(\.harness.displayName)
            .joined(separator: " and ")

        let installed = Alerts.confirm(
            title: "One last step",
            message: """
            \(agents) do not know lampboard exists yet. To make the traffic \
            lights react, \(HookConfigMerger.defaultEvents.count) hooks have to be \
            registered in each one's own configuration.

            Existing hooks are preserved and a backup copy is created. You can \
            remove them at any time from the panel's context menu (right-click).
            """,
            confirmTitle: "Install the hooks"
        )
        guard installed else { return }

        let reports = HookSetup.install(port: port)
        if HookSetup.hasFailure(in: reports) {
            // Named per agent rather than as one failure: one working and the
            // other not is a normal state, and the person has to be able to see
            // which is which.
            Alerts.warn(title: "Not everything was installed", message: HookSetup.summary(of: reports))
            return
        }
        Alerts.info(
            title: "Done",
            message: """
            \(HookSetup.summary(of: reports))

            Sessions that are already open pick up the new configuration the \
            next time they start.
            """
        )
    }
}

// MARK: - Crossing over to the main actor

extension AppDelegate {

    /// Runs `body` on the main actor and returns its result, giving up after
    /// `timeout` seconds.
    ///
    /// Needed by the HTTP routes that have to touch the interface: the server
    /// lives on its own queue and the result has to go into the response, so
    /// `async` isn't enough. A `sync` would be enough, but it would tie the
    /// server's queue to the main queue's availability forever.
    ///
    /// On expiry the work is **cancelled**, not abandoned. A plain
    /// `DispatchQueue.main.async` cannot be called back: if the main queue is
    /// busy, when it frees up it runs the block anyway and raises a window
    /// possibly minutes after the client was told "not now". A `DispatchWorkItem`
    /// cancelled before it starts, by contrast, never starts.
    ///
    /// What this function **cannot** do is unblock the main actor. If `body` gets
    /// stuck — `focus` goes through AppleScript, which can hang on an
    /// unresponsive app — the interface stays frozen regardless: the timeout
    /// protects the server's queue, not the main one. It is the same risk a click
    /// on a row already runs, so it adds no new one; it does add a way to trigger
    /// it from outside.
    static func onMain<T>(timeout: TimeInterval, _ body: @escaping @MainActor () -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)` is correct here: writes happen only on the main
        // queue, reads only after the semaphore has been signalled, and the two
        // never overlap.
        nonisolated(unsafe) var result: T?

        let work = DispatchWorkItem {
            MainActor.assumeIsolated { result = body() }
            semaphore.signal()
        }
        DispatchQueue.main.async(execute: work)

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            work.cancel()
            return nil
        }
        return result
    }
}

// MARK: - Clicking a notification

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Clicking the notification takes you **to that session**, not generically to
    /// the app: an alert that says "something is waiting" and then leaves you to
    /// find out which has saved nobody anything.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String

        Task { @MainActor in
            if let sessionId { self.notifier?.handleActivation(sessionId: sessionId) }
            completionHandler()
        }
    }
}
