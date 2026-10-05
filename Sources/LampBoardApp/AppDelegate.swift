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
    private lazy var settingsWindow = SettingsWindowController(fleet: fleet, lampMaster: lampMaster)
    /// Built with the panel, because it counts what the panel is showing.
    private var legendWindow: LegendWindowController?
    private var notifier: SessionNotifier?
    private var presence: PresenceFile?
    /// LampMaster's round. Started in every mode: the end-to-end suite drives
    /// it headless, and its timer does nothing while it is switched off.
    private lazy var mod = ModReceiver(store: store)
    /// What each session has been doing, for the Plancia (UX §5).
    private let activity = ActivityRecorder()
    /// The permissions the panel answers, when switched on (D80).
    private let permissions = PermissionDesk()
    /// Questions to live sessions without disturbing them (D82).
    private let askDesk = PeerAskDesk()
    private lazy var lampMaster = LampMasterService(preferences: preferences, rows: { [store] in store.sessions })
    private var lampMasterWindow: LampMasterWindowController?

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

        // The token is settled once, here, and both of the next two lines are
        // handed the same value. The repair ran before the server once, each
        // reading the store for itself — and on the launch that regenerates a
        // burned token, the repair read the old one, wrote it into every hook,
        // and the server then minted a new one nothing matched.
        let token = TokenStore().loadOrCreate()

        // Before the server answers anything: hooks written by an earlier version
        // carry no token, and this is where they stop being somebody's problem to
        // remember. Writes nothing when there is nothing to change.
        HookSetup.repairTokens(port: port, token: token)

        // A trial sets its stage before anything reads the home (D64).
        let trial = TrialStage.mode
        if trial != nil {
            TrialStage.prepare(.standard, preferences: preferences, files: LampMasterFiles())
        }

        startServer(token: token)

        // An installed mod of another version than the one carried here is
        // replaced, off the main thread: it runs `claude` up to four times.
        if trial == nil {
            DispatchQueue.global(qos: .utility).async { ModSetup.refreshIfStale() }
        }

        if !headless {
            startInterface()
        }

        store.startPolling()
        fleet.start()
        lampMaster.port = port
        lampMaster.start()
        if let trial { TrialStage.play(.standard, port: port, pace: trial.pace) }

        if !headless && trial == nil && shouldPromptForInstallation {
            preferences.wasSetupPromptShown = true
            promptForInstallation()
        }
    }

    /// Everything that only makes sense with a user in front of it.
    private func startInterface() {
        let controller = PanelController(store: store, installer: installer)
        controller.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        controller.lampMaster = lampMaster
        controller.activity = activity
        controller.permissionDesk = permissions
        controller.askDesk = askDesk
        mod.onReport = { [activity, askDesk] report, at in
            activity.record(report, at: at)
            askDesk.heard(report)
        }
        GettingStartedWindowController.shared.configure(
            port: port, lampMaster: lampMaster,
            toggleNotifications: { [weak controller] in controller?.toggleNotifications() }
        )
        if let trial = TrialStage.mode {
            let tour = TourController(fresh: trial.fresh)
            controller.tour = tour
            store.onSeen = { [weak tour] id in tour?.handle(.rowOpened(session: id)) }
            lampMaster.onReact = { [weak tour] in tour?.handle(.lampMasterAnswered) }
        }
        let lampMasterWindow = LampMasterWindowController(
            service: lampMaster, actions: controller.lampMasterActions(for: lampMaster)
        )
        self.lampMasterWindow = lampMasterWindow
        controller.onOpenLampMaster = { lampMasterWindow.show() }
        let legend = LegendWindowController(
            store: store,
            rendering: { [weak controller] in controller?.currentRendering ?? .empty }
        )
        legendWindow = legend
        controller.onOpenLegend = { legend.show() }
        controller.show()
        if TrialStage.mode != nil {
            controller.allowance.showTrial([DemoScript.standard.allowanceReport(now: Date())])
        } else {
            mod.onWindows = { [weak controller] windows in controller?.allowance.showFromMod(windows) }
        }
        // Opens the window at launch: for the screenshots, and for a check on a
        // Mac where nobody is there to click the menu.
        if CommandLine.arguments.contains("--getting-started") { GettingStartedWindowController.shared.show() }
        if CommandLine.arguments.contains("--settings") { settingsWindow.show() }
        // The Plancia on the most urgent session, once the first rows are in.
        if CommandLine.arguments.contains("--plancia") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak controller] in controller?.cycleDepth() }
            // And a message through its composer, as if typed — only against a
            // fake home: the test Mac's way to try the box (D81) without hands.
            if AppConfig.isUsingHomeOverride, let index = CommandLine.arguments.firstIndex(of: "--plancia-send"),
               CommandLine.arguments.indices.contains(index + 1) {
                let text = CommandLine.arguments[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak controller] in controller?.sendFromPlancia(text) }
            }
        }
        // What the bar does when typed in: only against a fake home, the test
        // Mac's way to try `@name message` (D81) without hands.
        if AppConfig.isUsingHomeOverride, let index = CommandLine.arguments.firstIndex(of: "--bar-type"),
           CommandLine.arguments.indices.contains(index + 1) {
            let text = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak controller] in controller?.typeIntoBar(text) }
        }
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
        lampMaster.stop()
        server?.stop()
        // The presence file has to go: leaving it would say "I'm at the Mac"
        // forever, and the phone push notifications would never arrive again.
        presence?.stop()
        presence?.remove()
        panelController?.close()
        if TrialStage.mode != nil { TrialStage.tearDown() }
    }

    // MARK: - Server

    private func startServer(token: String?) {
        if token == nil {
            Diagnostics.log("token unavailable: GET /sessions will stay closed")
        }

        let server = SignalServer(
            port: port,
            token: token,
            checkKey: TokenStore(url: AppConfig.checkKeyURL).loadOrCreate(),
            onSignal: { [store, lampMaster, activity] signal in
                Task { @MainActor in
                    store.handle(signal)
                    if signal.event == .stop || signal.event == .stopFailure {
                        activity.turnEnded(sessionId: signal.sessionId, at: Date())
                    }
                    if LampMasterService.nudgedBy.contains(signal.event) { lampMaster.nudge() }
                }
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
            },
            onLampMaster: { [lampMaster] in lampMaster.encodedState },
            onLampMasterRound: { [weak self] in
                Self.onMain(timeout: 2) { self?.lampMaster.request(.asked) } ?? false
            },
            onLampMasterTool: { [lampMaster] body in lampMaster.answer(body) },
            onMod: { [mod, lampMaster] report in
                Task { @MainActor in
                    mod.receive(report)
                    if case .tool(_, let run) = report, run.finished { lampMaster.nudge() }
                }
            },
            onWatch: { [store] report in
                Task { @MainActor in store.apply(.watched(report), now: Date()) }
            },
            onCheck: { [permissions] body, nonce, proof, key in permissions.check(body, nonce: nonce, proof: proof, key: key) },
            onChecks: { [permissions] in permissions.listing },
            onCheckAnswer: { [permissions] body in permissions.answer(body: body) },
            onBand: { [weak self] asking in
                Self.onMain(timeout: 1) { self?.bandItems(excluding: asking) } ?? Band.json([])
            },
            onBandOpen: { [weak self] session in
                Self.onMain(timeout: 2) { self?.panelController?.openFromBand(session) } ?? false
            }
        )

        do {
            try server.start()
            permissions.start()
            self.server = server
            ModReceiver.publishPort(port)
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
        // Right after the hooks, the one moment somebody is certainly looking at
        // LampBoard for the first time: the rest of the setup, and the tour.
        GettingStartedWindowController.shared.show()
    }
}

// MARK: - Crossing over to the main actor

extension AppDelegate {

    /// What the band shows a session (D84): the queue's cards, as the panel
    /// would draw them now, or nothing while the band is switched off. A
    /// session on a node is told who waits and how, not the command lines:
    /// they are this Mac's sessions' business (a review finding).
    @MainActor
    private func bandItems(excluding asking: String?) -> Data {
        guard Preferences().bandEnabled else { return Band.json([]) }
        let cards = WaitingQueue.cards(sessions: Array(store.state.sessions.values), suggestions: [],
                                       asks: permissions.pending, now: Date())
        let away = asking.flatMap { store.state.sessions[$0]?.workspace.isRemote } ?? false
        return Band.json(Band.items(cards: cards, excluding: asking, lines: !away))
    }

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
