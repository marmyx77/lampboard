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
            message: "lampboard will no longer receive signals from either agent."
        )
    }
}
