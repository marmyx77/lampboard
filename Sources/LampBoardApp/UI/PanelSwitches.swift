import AppKit
import LampBoardCore

/// The panel menu's switches that reach outside the panel — presence, terminal
/// sessions, launch at login — and the hooks' installation.
///
/// A separate file for the reason `PanelAllowance.swift` is one: `PanelController`
/// had reached the eight hundred lines this project refuses again, with the queue
/// of 0.6 still to wire in, and these are a whole subject of their own.
extension PanelController {

    func togglePresence() {
        let wanted = !preferences.presenceEnabled
        preferences.presenceEnabled = wanted

        if wanted {
            Alerts.info(
                title: "Phone push notifications suppressed while you're at the Mac",
                message: """
                Claude Code will skip the notifications on your phone for as long as \
                lampboard declares your presence.

                For this to work, the CLAUDE_CLIENT_PRESENCE_FILE variable has to \
                point at \(AppConfig.presenceFileURL.path).

                Careful: if the detection gets it wrong, the result is not one \
                notification too many but a notification lost.
                """
            )
        }
        rebuildContent()
    }

    /// "Show terminal sessions" (D25). Off takes its rows away at once; on lets
    /// the next poll adopt what is there, within five seconds.
    func toggleTerminalSessions() {
        let wanted = !preferences.showsTerminalSessions
        preferences.showsTerminalSessions = wanted
        if wanted {
            store.poll()
        } else {
            store.forgetTerminalSessions()
        }
        rebuildContent()
    }

    func toggleLaunchAtLogin() {
        if let failure = LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled) {
            Alerts.warn(title: "Launch at login", message: failure)
        }
        rebuildContent()
    }

    func installHooks() {
        // Every agent on this machine, and the alert names them: the menu used
        // to say "in Claude Code" and mean it, leaving Codex unregistered for
        // anyone who never opened a terminal to run the installer.
        let agents = HookSetup.state()
            .filter { $0.outcome != .notPresent }
            .map(\.harness.displayName)
            .joined(separator: " and ")

        guard Alerts.confirm(
            title: "Install the hooks?",
            message: """
            lampboard will register \(HookConfigMerger.defaultEvents.count) hooks in the \
            configuration of \(agents), so it knows when sessions change state.

            Existing hooks are preserved and a backup copy of each file is created. \
            Sessions that are already open pick up the new configuration the next \
            time they start.
            """,
            confirmTitle: "Install"
        ) else { return }

        let reports = HookSetup.install(includeMessageDelivery: preferences.messageSendingEnabled)
        rebuildContent()
        guard !HookSetup.hasFailure(in: reports) else {
            let summary = HookSetup.summary(of: reports)
            store.reportError(summary)
            Alerts.warn(title: "Not everything was installed", message: summary)
            return
        }
        Alerts.info(title: "Hooks installed", message: HookSetup.summary(of: reports))
    }

    func uninstallHooks() {
        // One click in a long menu should not cut every session off (U1).
        guard Alerts.confirm(
            title: "Disconnect Claude Code and Codex?",
            message: "LampBoard removes its lines from their settings and stops receiving signals. "
                + "The rows stay until their sessions end. You can connect again at any time.",
            confirmTitle: "Disconnect"
        ) else { return }
        let reports = HookSetup.remove()
        rebuildContent()
        guard !HookSetup.hasFailure(in: reports) else {
            let summary = HookSetup.summary(of: reports)
            store.reportError(summary)
            Alerts.warn(title: "Removal failed", message: summary)
            return
        }
        Alerts.info(
            title: "Hooks removed",
            message: "LampBoard will no longer receive signals from either agent."
        )
    }

    /// Turns answering from the panel on or off.
    ///
    /// Turning it **on** registers the delivery hook; turning it off removes it,
    /// so the resting state of a machine that never opted in has no listener, no
    /// mailbox and no way for anything to start a turn in the user's name.
    ///
    /// The dialog says what it costs, because this is the one switch here whose
    /// default is about safety rather than noise.
    func toggleMessageSending() {
        let wanted = !preferences.messageSendingEnabled

        if wanted {
            guard Alerts.confirm(
                title: "Send messages to sessions?",
                message: """
                You will be able to type and dictate into the conversation window \
                and the Plancia. A session of Claude Code 2.1.224 or later takes the \
                message at once through its own message box; an older one at the end \
                of its next turn. Either way the session acts on it with every \
                permission it already has: one that runs without asking will run \
                its tools at once.

                What it costs: for older sessions, delivery works through a file in ~/.lampboard/inbox, \
                and the reader cannot tell who wrote it. While this is on, anything \
                running under your account can start a turn that speaks with your \
                voice and your tools. Other accounts on this Mac are kept out; \
                processes of your own cannot be.

                Off, there is no listener and no mailbox at all, and the window \
                still shows you every conversation.
                """,
                confirmTitle: "Turn on"
            ) else { return }
        }

        preferences.messageSendingEnabled = wanted
        reinstallHooksForMessageSending()
        rebuildContent()
        refreshBar()
    }

    /// Re-registers the hooks so the delivery listener follows the switch.
    ///
    /// Claude Code alone, and deliberately: message delivery rides a second
    /// `Stop` hook that answers a mailbox, and Codex has no path back into a
    /// session to answer through. Everything else about installing goes through
    /// `HookSetup` and reaches both agents; this one thing is not shared because
    /// only one agent has it.
    func reinstallHooksForMessageSending() {
        guard installer.isInstalled() else { return }
        do {
            try installer.install(includeMessageDelivery: preferences.messageSendingEnabled)
        } catch {
            store.reportError(error.localizedDescription)
        }
    }
}
