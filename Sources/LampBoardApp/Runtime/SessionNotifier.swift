import AppKit
import AVFoundation
import LampBoardCore
import Combine
import Foundation
import UserNotifications

/// Sends a system notification when a session gets **blocked**, or a turn
/// fails; a finished turn only when asked for (D9, revisited for 0.5).
///
/// Amber and red, not green, unless asked. That distinction is the whole feature: a ready
/// answer can wait until you look at it, a permission cannot — until you answer,
/// that work is stopped. Notifying on green as well, with a dozen sessions open,
/// would produce tens of alerts a day, and a channel that alerts too often gets
/// switched off within two days. Then the real blocks would stop arriving too.
@MainActor
final class SessionNotifier {

    private let store: StateStore
    private let preferences: Preferences
    private let onOpen: (SessionState) -> Void

    /// The sessions an alert has already gone out for.
    ///
    /// Without a memory, every state recomputation would resend the same
    /// notification: the column updates continuously, and a repeated notification
    /// is worse than no notification.
    /// Scheduled while something is amber but not yet old enough to announce.
    private var recheck: Timer?

    private var announced: Set<String> = []

    private var cancellables = Set<AnyCancellable>()
    private var isPanelVisible: () -> Bool = { false }
    private var authorized = false
    /// Each session's status at the last pass, to tell a turn that just failed
    /// or finished from one that already had. `nil` before the first pass, so
    /// what was already so at launch is not news.
    private var lastStatus: [String: SessionStatus]?
    /// The voice (D117): kept, so an utterance is not cut by its owner going.
    private let voice = AVSpeechSynthesizer()
    private let voiceLog = VoiceLog()
    /// What waited while a session was in focus (G1).
    private var hold = FocusHold()
    /// The session in focus has been seen in this run: once it goes, the focus
    /// goes with it, and does not come back if the id ever does.
    private var focusSeen = false

    init(
        store: StateStore,
        preferences: Preferences,
        onOpen: @escaping (SessionState) -> Void
    ) {
        self.store = store
        self.preferences = preferences
        self.onOpen = onOpen
    }

    func start(isPanelVisible: @escaping () -> Bool) {
        self.isPanelVisible = isPanelVisible

        store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.react(to: state) }
            .store(in: &cancellables)

        // Authorization is requested only when the feature is on: asking at
        // startup would put a system dialog in front of somebody who never wanted
        // it, and at that point the most likely answer is "no" forever.
        if preferences.notificationsEnabled { requestAuthorization() }
    }

    /// Requests permission to notify. To be invoked when the user turns the switch
    /// on, that is, while they are there reading the dialog.
    func requestAuthorization(then completion: ((Bool) -> Void)? = nil) {
        guard Bundle.main.bundleIdentifier != nil else {
            // Outside a bundle `UNUserNotificationCenter` is unusable and trying
            // would terminate the process. This happens when the bare binary is
            // launched from a terminal.
            Diagnostics.log("notifications unavailable: the app is not running as a bundle")
            completion?(false)
            return
        }

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                Task { @MainActor in
                    self?.authorized = granted
                    // The outcome is logged **always**, not just on failure. An
                    // accessory app is never frontmost, and the authorization
                    // dialog may not appear at all: without this line "denied" and
                    // "never asked" are indistinguishable from the outside, and you
                    // end up hunting for the defect in delivery.
                    Diagnostics.log(
                        "notification authorization: \(granted ? "GRANTED" : "DENIED")"
                            + (error.map { ": \($0.localizedDescription)" } ?? "")
                    )
                    completion?(granted)
                }
            }
    }

    // MARK: - Reacting to state changes

    private func react(to state: TrafficLightState) {
        // The focus taken off, or its session gone: what waited is said now (G1).
        if let id = preferences.focusedSession {
            if state.sessions[id] != nil { focusSeen = true }
            else if focusSeen { preferences.focusedSession = nil; focusSeen = false }
        }
        let focused = focus(in: state)
        if hold.focused != focused { focusChanged(to: focused, in: state) }
        announceTransitions(in: state)
        let blocked = state.sessions.values.filter { $0.status == .awaiting }
        let blockedIds = Set(blocked.map(\.id))

        // Anything that has become unblocked is a candidate again: if it blocks
        // tomorrow, that is a new event and deserves a new alert.
        announced.formIntersection(blockedIds)

        // With the feature off we still take note of what is already blocked.
        // Without that, switching it on with ten stalled sessions would fire ten
        // notifications at once — precisely the burst that makes people disable a
        // channel and never re-enable it.
        //
        // What gets notified is a **transition**, not a state: whatever was already
        // that way before you asked to be told is not news.
        guard preferences.notificationsEnabled else {
            announced.formUnion(blockedIds)
            return
        }

        // The earliest moment one of the young ones becomes old enough.
        var soonest = TimeInterval.greatestFiniteMagnitude

        for session in blocked where !announced.contains(session.id) {
            // Waiting long enough to be waiting **for somebody**. A permission a
            // person answers stays amber until they do; one the agent approves
            // itself lasts a few hundred milliseconds, and Codex publishes a
            // request for every tool call either way. Announcing on the
            // transition turned a session working through a task into a burst of
            // alerts about nothing.
            //
            // Not marked as announced while it is too young, or it would never be
            // announced at all: the next pass has to be able to reconsider it.
            let waited = Date().timeIntervalSince(session.statusSince)
            guard waited >= AppConfig.awaitingNotificationDelay else {
                soonest = min(soonest, AppConfig.awaitingNotificationDelay - waited)
                continue
            }

            announced.insert(session.id)
            guard passesGate(session), passesFocus(session, event: .waiting, in: state) else { continue }
            if deliver(session, event: .waiting) { speak(session) }
        }

        // Come back for the ones that were too young. The store publishes only
        // when the state **changes**, so a session sitting amber with nothing else
        // happening would never be looked at again, and a real permission prompt
        // would wait for an unrelated event to be announced. In practice another
        // session usually moves within seconds, which is exactly the kind of
        // accidental correctness that holds until the one morning it matters.
        recheck?.invalidate()
        recheck = nil
        guard soonest < .greatestFiniteMagnitude else { return }
        recheck = Timer.scheduledTimer(withTimeInterval: soonest + 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.react(to: state) }
        }
    }

    /// A turn that has just died, always; one that has just finished with an
    /// answer, when asked for (5.6). On the transition only: a session already
    /// red or green at launch, or when the switch went on, is not news.
    private func announceTransitions(in state: TrafficLightState) {
        let now = state.sessions.mapValues(\.status)
        defer { lastStatus = now }
        guard let before = lastStatus, preferences.notificationsEnabled else { return }
        for session in state.sessions.values where before[session.id] != session.status {
            switch session.status {
            case .failed where passesGate(session) && passesFocus(session, event: .failed, in: state):
                deliver(session, event: .failed)
            case .ready where preferences.notifyFinished && passesGate(session) && passesFocus(session, event: .finished, in: state):
                deliver(session, event: .finished)
            default:
                continue
            }
        }
    }

    /// The gate deciding whether the alert is really needed.
    ///
    /// Only the **explicit** silences remain: the ones the user asked for.
    ///
    /// There used to be a presence condition too — no alert if the panel is
    /// visible and you touched the Mac recently — and it was removed in the face
    /// of the evidence. The reasoning looked sound: if you're looking at the
    /// screen, you can already see the amber dot. But the panel is **floating**,
    /// which means it is on screen by construction; and if you're at the Mac,
    /// you're active. The two conditions were therefore almost always true
    /// together, and the result was an inert feature: you switched it on and
    /// nothing ever arrived.
    ///
    /// Measured, not deduced: the first test notification ended up in the log as
    /// "suppressed (panel visible, idle for 62s)" while the user was in another
    /// application, waiting for it.
    ///
    /// "Visible" does not mean "looked at". A two-hundred-pixel panel in the
    /// corner of three screens is on screen and out of attention, and that is
    /// exactly the situation where a notification is needed.
    ///
    /// What stands in its place: the memory that avoids duplicates, the per-project
    /// silence and the timed one. Three **explicit** checks, which the user chooses
    /// and can see — instead of one implicit check that swallows alerts silently.
    /// Away (A1): nothing interrupts; the ledger says it all on return.
    var isAway: () -> Bool = { false }

    private func passesGate(_ session: SessionState) -> Bool {
        if isAway() {
            Diagnostics.log("notification held while away: \(session.workspace.name)")
            return false
        }
        if let until = preferences.mutedUntil, until > Date() {
            Diagnostics.log("notification suppressed (muted until \(until)): \(session.workspace.name)")
            return false
        }
        if preferences.mutedWorkspaces.contains(session.workspace.key) {
            Diagnostics.log("notification suppressed (project muted): \(session.workspace.name)")
            return false
        }

        return true
    }

    /// While a session is in focus the others' notifications wait (G1), kept
    /// for the line that says what waited.
    private func passesFocus(_ session: SessionState, event: NotificationText.Event, in state: TrafficLightState) -> Bool {
        let focused = focus(in: state)
        if hold.focused != focused { focusChanged(to: focused, in: state) }
        guard !hold.admits(session.id) else { return true }
        let name = RowNames.name(of: session.workspace.key, in: preferences.rowNames) ?? session.displayName
        hold = hold.holding(event, sessionId: session.id, name: RowActivity.flat(name))
        Diagnostics.log("notification held for the focus: \(session.workspace.name)")
        return false
    }

    /// The session in focus, when it is one the state has.
    private func focus(in state: TrafficLightState) -> String? {
        preferences.focusedSession.flatMap { state.sessions[$0] == nil ? nil : $0 }
    }

    /// The focus moved or went: what waited, and is still so, is said in one
    /// notification — unless everything is silenced for now.
    func focusChanged(to focused: String?, in state: TrafficLightState? = nil) {
        let state = state ?? store.state
        let current = hold.keeping { held in
            guard let session = state.sessions[held.sessionId],
                  !preferences.mutedWorkspaces.contains(session.workspace.key) else { return false }
            return held.event != .waiting || session.status == .awaiting
        }
        let silenced = (preferences.mutedUntil.map { $0 > Date() }) ?? false
        if let summary = current.summary(), preferences.notificationsEnabled, !silenced { deliverSummary(summary) }
        hold = FocusHold(focused: focused)
    }

    func deliverSummary(_ text: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "LampBoard"
        content.body = text
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "lampboard.focus.\(UUID().uuidString)", content: content, trigger: nil)
        ) { error in
            Task { @MainActor in
                Diagnostics.log(error.map { "focus summary NOT delivered: \($0.localizedDescription)" } ?? "focus summary delivered")
            }
        }
    }

    /// Whether a notification went out: never from a bare binary, which a
    /// test panel or a `swift run` is.
    @discardableResult
    private func deliver(_ session: SessionState, event: NotificationText.Event) -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }

        let content = UNMutableNotificationContent()
        content.title = RowNames.name(of: session.workspace.key, in: preferences.rowNames) ?? session.displayName
        // What happened, in a line: the command or question waiting, why the
        // turn died, the answer's first line. Never the previous turn's reply
        // for a waiting session (`NotificationText`).
        content.body = NotificationText.body(for: event, session: session)
        content.sound = .default
        // Carries the session id: clicking the notification has to take you *there*,
        // not generically to the app.
        content.userInfo = ["sessionId": session.id]

        let request = UNNotificationRequest(
            identifier: "lampboard.\(event).\(session.id)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                if let error {
                    Diagnostics.log("notification NOT delivered: \(error.localizedDescription)")
                } else {
                    Diagnostics.log("notification delivered: \(session.workspace.name)")
                }
            }
        }
        return true
    }

    /// Said aloud too, to someone near the Mac but away from its keys (D117).
    private func speak(_ session: SessionState) {
        guard preferences.speakWaiting else { return }
        let idle = Self.secondsSinceLastInput(), locked = PresenceFile.isScreenLocked
        guard SpokenAlert.speaks(enabled: true, idle: idle, locked: locked) else {
            return Diagnostics.log("not spoken (idle \(Int(idle)) s\(locked ? ", locked" : "")): \(session.workspace.name)")
        }
        let name = RowNames.name(of: session.workspace.key, in: preferences.rowNames) ?? session.displayName
        voice.delegate = voiceLog
        // The latest is what matters: a sentence still queued would be said
        // after the person is back at the keys.
        if voice.isSpeaking { voice.stopSpeaking(at: .word) }
        voice.speak(AVSpeechUtterance(string: SpokenAlert.sentence(name: name)))
        Diagnostics.log("speaking: \(session.workspace.name)")
    }

    /// Opens the session named by a notification that was clicked.
    func handleActivation(sessionId: String) {
        guard let session = store.state.sessions[sessionId] else { return }
        onOpen(session)
    }

    // MARK: - User presence

    /// Seconds elapsed since the last keyboard or mouse event.
    ///
    /// `CGEventSource` answers even an accessory app without extra permissions:
    /// it does not read *what* was pressed, only *when*.
    static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
    }
}

/// Says in the log that an utterance was heard to the end, or cut.
private final class VoiceLog: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Diagnostics.log("spoken: \(utterance.speechString)")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Diagnostics.log("speech cut: \(utterance.speechString)")
    }
}
