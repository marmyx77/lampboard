import AppKit
import Combine
import LampBoardCore

/// The one switch in this panel that makes the app talk to a service instead of
/// to this Mac.
///
/// A separate file for the reason `PanelHomes.swift` is one: `PanelController`
/// had reached the eight hundred lines this project refuses, and the honest
/// answer is to take a subject out rather than to raise the number. The subject
/// here is small but whole — everything about asking Anthropic for the
/// allowance, and nothing else.
extension PanelController {

    /// The allowance strip changes the panel's **height**, so the window has to be
    /// remeasured when it arrives, disappears, or gains a second account. Without
    /// this the strip drew into the room the rows were using and the projects at
    /// the bottom went off the end — which is what happened the first time.
    func observeAllowance() {
        allowance.$reports
            .map(\.count)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resizeToFit(self.store.state)
            }
            .store(in: &cancellables)
    }

    /// "Show how much of your allowance is left". **Off by default, and the only
    /// switch here that sends anything off this Mac.**
    ///
    /// Turning it on is told, not slipped past. Everywhere else the app reads
    /// files that are already on the machine; this asks `api.anthropic.com` every
    /// couple of minutes, signed with Claude Code's own credential. Somebody who
    /// chose this app partly because nothing leaves the Mac is owed the sentence
    /// before the first request, not in a changelog afterwards.
    func toggleUsage() {
        let wanted = !preferences.usageEnabled
        preferences.usageEnabled = wanted
        allowance.hosts = preferences.remoteHosts
        allowance.apply(enabled: wanted)

        if wanted {
            Alerts.info(
                title: "The panel will now ask Anthropic about your allowance",
                message: """
                Every \(Int(AppConfig.usagePollInterval / 60)) minutes or so lampboard asks                 api.anthropic.com how much of your account's allowance is gone — the same                 figures /usage shows — and draws them under the column.

                It signs the request with the token Claude Code already keeps in your                 keychain. It only reads it: renewing that token could sign you out of                 Claude Code, so if the token is too old the strip simply goes quiet until                 Claude Code refreshes it.

                This is the only thing lampboard sends anywhere apart from the update                 check. Switch it off and it stops immediately.
                """
            )
        }
        rebuildContent()
    }
}
