import AppKit
import Foundation
import LampBoardCore

/// Where the person is, told to the phone's notifications and to every node's
/// `lampd` (W5, Q8, §2.6 «Sonno»), apart from the delegate's start.
extension AppDelegate {

    /// Away from the menu or a locked screen (D114), and the Mac going to
    /// sleep: in every mode, headless included, so the gate can say it.
    func startAway() {
        let away = AwayMonitor(store: store, preferences: preferences, flag: awayFlag)
        away.onAwayChange = { [weak self] gone in self?.tellPresence(gone ? .away : .here) }
        self.away = away
        away.start()
        let center = NSWorkspace.shared.notificationCenter
        sleepWatch.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The nodes first (a line down each tunnel, at once), then the
                // phone's last word, which waits a few seconds for the relay.
                self.fleet.setPresence(.asleep)
                self.mobile.setPresence(.asleep)
                self.mobile.sleeping()
            }
        })
        sleepWatch.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tellPresence((self.away?.isAway ?? false) ? .away : .here)
            }
        })
        tellPresence(away.isAway ? .away : .here)
    }

    func tellPresence(_ presence: MacPresence) {
        fleet.setPresence(presence)
        mobile.setPresence(presence)
    }
}
