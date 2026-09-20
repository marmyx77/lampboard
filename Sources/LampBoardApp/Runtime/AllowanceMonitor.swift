import LampBoardCore
import Foundation
import SwiftUI

/// Keeps the account's allowance figures fresh while the switch is on.
///
/// Small on purpose. It owns one timer and one value, and everything difficult —
/// the borrowed credential, the network, the refusal to renew a token that is not
/// ours — lives in `AccountLimitsReader`. What is decided here is only *when* to
/// ask and *whether* to ask at all.
///
/// WHY IT STOPS COMPLETELY WHEN THE SWITCH IS OFF
/// Not paused, not throttled: no timer and no request. A feature that reaches the
/// network is either off or it is on, and one that keeps a heartbeat going while
/// claiming to be off is the kind of thing that makes a privacy sentence false
/// without anybody having lied on purpose.
@MainActor
final class AllowanceMonitor: ObservableObject {

    /// One group of bars per account, local first. Empty while the switch is off,
    /// before the first ask, or when nothing could be read.
    @Published private(set) var reports: [AllowanceReport] = []

    /// Why there is nothing, when there is nothing. Only ever the **local**
    /// machine's reason: a node that is signed out or unreachable is not something
    /// to report on a strip about allowances, and one line per silent host would
    /// turn a decoration into a status board.
    @Published private(set) var quiet: String?

    private var timer: Timer?
    private var inFlight = false

    /// The machines to ask besides this one.
    ///
    /// Set from the preferences, because the account a node is signed in as is not
    /// knowable from here: measured on 20 September 2026, this Mac is an
    /// organization account and the node most of the work happens on is a personal
    /// one, on a different plan. Reading only this Mac would draw a bar that is
    /// **wrong** for the machine the person is actually working on.
    var hosts: [String] = []

    /// Turns the polling on or off to match the preference.
    ///
    /// Safe to call on every change of anything: an `on` while already running
    /// keeps the existing timer rather than stacking a second one, which is the
    /// defect this shape exists to make impossible.
    func apply(enabled: Bool) {
        guard enabled else { return stop() }
        guard timer == nil else { return }

        // Ask at once. A strip that stayed empty for two and a half minutes after
        // the switch was flipped reads as a feature that does not work.
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: AppConfig.usagePollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The panel's run loop spends its time in tracking mode while somebody is
        // dragging a row, and a timer on the default mode alone simply stops for
        // as long as the mouse is down.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        // Cleared, not kept: a figure left on screen after the switch went off
        // would be the panel still showing what it promised to stop asking.
        reports = []
        quiet = nil
    }

    private func refresh() {
        // A request still open when the next tick arrives is a slow network, not a
        // reason to open a second one.
        guard !inFlight else { return }
        inFlight = true
        let hosts = self.hosts
        Task { @MainActor [weak self] in
            let result = await AccountLimitsReader.readAll(hosts: hosts)
            guard let self else { return }
            // Released whatever happened. Clearing it only on the path that still
            // has a timer would leave the flag stuck after a switch-off mid-flight,
            // and the feature would then never ask again once switched back on —
            // a dead monitor that looks exactly like a quiet one.
            self.inFlight = false
            // The answer to a request that outlived its own switch is discarded:
            // arriving after `stop()` it would put a figure back on a strip the
            // person has just turned off.
            guard self.timer != nil else { return }
            self.reports = result.reports
            self.quiet = result.quiet
        }
    }
}
