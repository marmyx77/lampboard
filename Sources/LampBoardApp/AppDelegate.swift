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
    /// The nonces of the handoffs taken (D91): a proof heard twice counts once.
    private var handoffNonces = Set<String>()
    private var notifier: SessionNotifier?
    private var presence: PresenceFile?
    /// LampMaster's round. Started in every mode: the end-to-end suite drives
    /// it headless, and its timer does nothing while it is switched off.
    private lazy var mod = ModReceiver(store: store)
    /// What each session has been doing, for the Plancia (UX §5).
    private let activity = ActivityRecorder()
    /// The permissions the panel answers, when switched on (D80).
    private let permissions = PermissionDesk()
    private let decisions = DecisionBoardService()
    private var away: AwayMonitor?
    private let awayFlag = AwayFlag()
    private let governor = GovernorService()
    /// Questions to live sessions without disturbing them (D82).
    private let askDesk = PeerAskDesk()
    /// Every conversation of this Mac, searchable (0.7); kept up off the main thread.
    let searchIndex = SearchIndex()
    private var indexClock: DispatchSourceTimer?
    private lazy var lampMaster = LampMasterService(preferences: preferences, rows: { [store] in store.sessions })

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

        // What each session's tools did, with or without a panel on screen: the
        // radar (§4.4) answers from it either way.
        mod.onReport = { [activity, askDesk] report, at in
            activity.record(report, at: at)
            askDesk.heard(report)
        }

        if !headless {
            startInterface()
        }

        store.startPolling()
        fleet.start()
        lampMaster.port = port
        // Earlier conversations for `who_knows` (D89), with or without a panel on screen.
        lampMaster.remember = { [searchIndex] words in
            searchIndex.search(words, limit: 6).map {
                LampMasterLookup.Remembered(sessionId: $0.sessionId, title: $0.title ?? "untitled",
                                            project: $0.cwd.map { ($0 as NSString).lastPathComponent }, lastAt: $0.lastAt)
            }
        }
        lampMaster.precedentsSearch = { [searchIndex] words in
            searchIndex.search(words, limit: 8).map {
                LampMasterPrecedents.Hit(sessionId: $0.sessionId, project: $0.cwd.map { ($0 as NSString).lastPathComponent },
                                         lastAt: $0.lastAt, snippet: $0.snippet)
            }
        }
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
        controller.searchIndex = searchIndex
        controller.decisionBoard = decisions
        controller.governor = governor
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
        // In the panel, beside the list (UX §4): no window of its own.
        controller.onOpenLampMaster = { [weak controller] in controller?.openLampMasterPlancia() }
        let legend = LegendWindowController(
            store: store,
            rendering: { [weak controller] in controller?.currentRendering ?? .empty }
        )
        legendWindow = legend
        controller.onOpenLegend = { legend.show() }
        lampMaster.allowance = { [weak controller] in controller?.allowance.reports ?? [] }
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
        if CommandLine.arguments.contains("--legend") { legendWindow?.show() }
        // LampMaster's Plancia on one of its sheets (D96): `--lampmaster today`.
        if let index = CommandLine.arguments.firstIndex(of: "--lampmaster"), CommandLine.arguments.indices.contains(index + 1),
           let sheet = LampMasterPlanciaContent.Sheet(rawValue: CommandLine.arguments[index + 1].capitalized) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak controller] in controller?.openLampMasterPlancia(sheet: sheet) }
        }
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
        startIndexing()
    }

    /// One pass of the search index every 30 seconds, at utility priority, a
    /// budget each, while it is switched on; the first build of a long history
    /// spreads over passes instead of one heavy minute.
    private func startIndexing() {
        let index = searchIndex
        let clock = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        clock.schedule(deadline: .now() + 10, repeating: 30, leeway: .seconds(5))
        clock.setEventHandler {
            guard Preferences().searchIndexed else { return }
            let done = index.update()
            if done.files > 0 { Diagnostics.log("index: \(done.files) transcripts, \(done.messages) messages") }
        }
        clock.resume()
        indexClock = clock
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
        controller.onFocusChanged = { [weak notifier] focused in notifier?.focusChanged(to: focused) }

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

        let away = AwayMonitor(store: store, preferences: preferences, flag: awayFlag)
        notifier?.isAway = { [weak away] in away?.isAway ?? false }
        away.onBack = { [weak self] line in
            if self?.preferences.notificationsEnabled == true { self?.notifier?.deliverSummary(line) }
            self?.panelController?.rebuildContent()
            if let store = self?.store { self?.panelController?.resizeToFit(store.state) }
        }
        panelController?.away = away
        away.start()
        self.away = away
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
            onQuestion: { [permissions] body, nonce, proof, key in permissions.question(body, nonce: nonce, proof: proof, key: key) },
            onBand: { [weak self] asking in
                Self.onMain(timeout: 1) { self?.bandItems(excluding: asking) } ?? Band.json([])
            },
            onBandOpen: { [weak self] session in
                Self.onMain(timeout: 2) { self?.panelController?.openFromBand(session) } ?? false
            },
            onHandoff: { [weak self] body, nonce, proof, key in
                guard let request = Handoff.request(body, nonce: nonce, proof: proof, key: key), let nonce else {
                    return "LampBoard could not read the handoff, or it was not proven."
                }
                return Self.onMain(timeout: 2) { () -> String? in
                    // Each proof once: one heard again is not a second handoff.
                    guard let self, self.handoffNonces.insert(nonce).inserted else { return "That handoff was already taken." }
                    return self.panelController?.receive(handoff: request)
                } ?? "LampBoard's panel is not ready."
            },
            onDecisions: { [decisions] body in decisions.handle(body) },
            onModDecisions: { [weak self, decisions] body, nonce, proof, key in
                guard let session = DecisionBoardExchange.provenSession(body, nonce: nonce, proof: proof, key: key),
                      let nonce else { return "" }
                // "" is a row with no repository; nil is no row, or no answer from
                // the main actor in time — not knowing, which must not read as
                // "nothing pinned" and withdraw what the session was told.
                guard let repository = Self.onMain(timeout: 1, { self?.store.state.sessions[session].map { $0.git?.repo ?? "" } })
                else { return "" }
                return DecisionBoardExchange.answer(board: decisions.current, repository: repository.isEmpty ? nil : repository,
                                                    nonce: nonce, key: key)
            },
            onModGovernor: { [governor, preferences] body, nonce, proof, key in
                guard let session = GovernorExchange.provenSession(body, nonce: nonce, proof: proof, key: key),
                      let nonce else { return "" }
                // The session in focus is never lowered, whenever it was put there.
                let focused = preferences.focusedSession == session
                return GovernorExchange.answer(model: focused ? nil : governor.model(for: session), nonce: nonce, key: key)
            },
            onModRadar: { [weak self] body, nonce, proof, key in
                guard let request = RadarExchange.provenRequest(body, nonce: nonce, proof: proof, key: key),
                      let nonce else { return "" }
                // Read where the logs and the rows live; no answer in time is "clear".
                let reason = Self.onMain(timeout: 1) { () -> String? in
                    guard let self else { return nil }
                    let now = Date()
                    guard let writer = FileConflicts.lastWriter(of: request.file, besides: request.session,
                                                                logs: self.activity.logs,
                                                                live: Set(self.store.state.sessions.keys), now: now),
                          let other = self.store.state.sessions[writer.session] else { return nil }
                    let name = RowNames.name(of: other.workspace.key, in: self.preferences.rowNames) ?? other.displayName
                    return RadarExchange.reason(file: request.file, by: name,
                                                minutesAgo: Int(now.timeIntervalSince(writer.at) / 60))
                } ?? nil
                return RadarExchange.answer(reason: reason, nonce: nonce, key: key)
            },
            onModHold: { [awayFlag] body, nonce, proof, key in
                guard let request = HoldExchange.provenRequest(body, nonce: nonce, proof: proof, key: key),
                      let nonce else { return "" }
                let reason = HoldExchange.reason(command: request.command, cut: request.cut, away: awayFlag.isAway)
                return HoldExchange.answer(reason: reason, nonce: nonce, key: key)
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
