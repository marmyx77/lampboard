import AppKit
import LampBoardCore
import Foundation

/// Persisted panel preferences.
///
/// There are few of them and none carry consequences, so they live in
/// `UserDefaults` rather than a configuration file: losing them costs the user
/// nothing.
struct Preferences {
    private enum Key {
        static let compact = "panel.compact"
        /// The panel's left edge and its **top**. Deliberately new keys: the
        /// ones before them held the bottom, and reading that as a top would
        /// move every existing panel by its own height, once.
        static let anchorX = "panel.anchor.x"
        static let anchorTop = "panel.anchor.top"
        static let setupPromptShown = "setup.promptShown"
        static let opensSessionTab = "click.opensSessionTab"
        static let onlyWaiting = "panel.onlyWaiting"
        /// Read only, as the seed of `rowOrder` for whoever upgrades from the
        /// pinned-rows version.
        static let pinnedWorkspaces = "panel.pinnedWorkspaces"
        static let rowOrder = "panel.rowOrder"
        static let remoteHosts = "remote.hosts"
        static let hiddenWorkspaces = "panel.hiddenWorkspaces"
        static let dismissedSessions = "panel.dismissedSessions"
        static let mutedWorkspaces = "notify.mutedWorkspaces"
        static let notificationsEnabled = "notify.enabled"
        static let mutedUntil = "notify.mutedUntil"
        static let messageSendingEnabled = "chat.sendingEnabled"
        static let presenceEnabled = "presence.enabled"
        static let usageEnabled = "usage.enabled"
        static let terminalSessions = "terminal.sessions"
        static let rowNames = "panel.rowNames"
        static let calmBlinkWorkspaces = "panel.calmBlink"
        static let expandedRows = "panel.expandedRows"
        static let conversationOrder = "panel.conversationOrder"
        static let menuBarIcon = "menubar.icon"
        static let panelPlacement = "panel.placement"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = Preferences.sharedDefaults) {
        self.defaults = defaults
    }

    /// Where the preferences end up.
    ///
    /// With `LAMPBOARD_HOME` set, a separate domain is used, because the
    /// end-to-end tests launch the real app and without this detour their
    /// preferences would get mixed in with the user's: a test that switches a
    /// notification on would leave it switched on afterwards.
    static let sharedDefaults: UserDefaults = {
        guard AppConfig.isUsingHomeOverride else { return .standard }
        let suite = "com.lampboard.app.test.\(AppConfig.homeDirectory.lastPathComponent)"
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// The preference domain this app had before it was renamed.
    ///
    /// `UserDefaults.standard` is keyed on the bundle identifier, so renaming the
    /// bundle does not move preferences: it hides them. Everything the user chose
    /// is still on disk under the old name and simply never read again.
    private static let legacyDomain = "com.clawdlight.app"

    /// Marks that the one-time import has happened, so it never runs twice.
    private static let migrationKey = "migrated.from.clawdlight"

    /// Brings across everything the previous name held, once.
    ///
    /// This is not housekeeping. What lives here is the part of the app that is
    /// **the user's**: the names they gave the rows, the order they dragged them
    /// into, where on the screen they put the panel, whether notifications are
    /// on. A rename that silently discarded that would be indistinguishable, from
    /// where they sit, from the app forgetting who they are — and the row names
    /// in particular took real thought to write and are nowhere else on disk.
    ///
    /// Everything is copied, not a chosen subset. The domain holds window frames
    /// and other keys AppKit writes without asking anybody, and a migration that
    /// listed what to carry would drop each new key added after it was written,
    /// silently, in exactly the way nobody notices for a year.
    ///
    /// It runs before anything reads a preference, so the first read already sees
    /// the imported value. That ordering is the whole of the correctness here: a
    /// getter that imports on first read — `remoteHosts` has one — will otherwise
    /// have already written its empty default and closed the door.
    static func migrateFromPreviousName(into defaults: UserDefaults = Preferences.sharedDefaults) {
        guard !AppConfig.isUsingHomeOverride else { return }
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let legacy = UserDefaults(suiteName: legacyDomain),
              let values = legacy.persistentDomain(forName: legacyDomain),
              !values.isEmpty
        else { return }

        var imported = 0
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            imported += 1
        }
        Diagnostics.log("preferences: imported \(imported) keys from \(legacyDomain)")
    }

    var isCompact: Bool {
        get { defaults.bool(forKey: Key.compact) }
        nonmutating set { defaults.set(newValue, forKey: Key.compact) }
    }

    /// `true` when a lamp sits in the menu bar beside the clock. **Off by
    /// default**, like everything here that puts something on screen the user
    /// did not ask for.
    ///
    /// Independent of `home` on purpose. The icon is a second surface and
    /// not a second mode: somebody who keeps the panel floating all day may
    /// still want the lamp up there for the moments the panel is behind a full
    /// screen window, and the two switches let them have both.
    var showsMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.menuBarIcon) }
        nonmutating set { defaults.set(newValue, forKey: Key.menuBarIcon) }
    }

    /// Where the panel appears. Floating unless it was moved into the menu bar.
    ///
    /// Stored as a string rather than an integer: a number in a preferences file
    /// means nothing to whoever reads it later, and this one is going to be read
    /// by somebody debugging a panel that did not come back.
    var home: PanelHome {
        get { PanelHome(rawValue: defaults.string(forKey: Key.panelPlacement) ?? "") ?? .floating }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.panelPlacement) }
    }

    /// `true` when the click, after raising the window, also opens the session's
    /// tab. **Off by default.**
    ///
    /// It used to be on, and was switched off in the face of the evidence. Two
    /// defects, both visible only once raising the window actually started
    /// working — before that the deep link never fired, because it only fires
    /// after a successful raise:
    ///
    /// 1. VS Code asks for permission on **every** invocation ("Allow an
    ///    extension to open this URI?"). A click that asks for confirmation is
    ///    no longer a click.
    ///
    /// 2. The extension reuses the tab only if it already has one registered for
    ///    that session id (`sessionPanels.get(id)?.reveal()`); otherwise it
    ///    **creates a new one**. That always happens for integrated-terminal
    ///    sessions, which have no Claude panel at all. The result is one extra
    ///    empty tab per click.
    ///
    /// The click still keeps its promise — taking you to the right window —
    /// because that part is done by the accessibility raise, not by the deep
    /// link. Anyone who wants the tab too can switch it back on from the menu.
    var opensSessionTab: Bool {
        get { defaults.object(forKey: Key.opensSessionTab) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.opensSessionTab) }
    }

    /// `true` when the offer to install the hooks has already been shown.
    /// Somebody who declines once doesn't want it offered again at every startup.
    var wasSetupPromptShown: Bool {
        get { defaults.bool(forKey: Key.setupPromptShown) }
        nonmutating set { defaults.set(newValue, forKey: Key.setupPromptShown) }
    }

    // MARK: - Scale

    /// `true` when the column shows only what is waiting for something.
    var showsOnlyWaiting: Bool {
        get { defaults.bool(forKey: Key.onlyWaiting) }
        nonmutating set { defaults.set(newValue, forKey: Key.onlyWaiting) }
    }

    /// The column's order, by project path. Position `i` is drawn `i`-th and is
    /// slot `i + 1`.
    ///
    /// Data the user arranged, not a derived value: it survives restarts as
    /// written, and `StateStore` gives every newly seen project a place at the
    /// bottom. Whoever upgrades from the pinned-rows version finds their pins at
    /// the top, in slot order — the pins *were* the arranged part of the old
    /// column, and everything else joins below as it is seen.
    var rowOrder: [String] {
        get {
            RowOrder.normalized(
                defaults.stringArray(forKey: Key.rowOrder)
                    ?? defaults.stringArray(forKey: Key.pinnedWorkspaces)
                    ?? []
            )
        }
        nonmutating set {
            defaults.set(RowOrder.normalized(newValue), forKey: Key.rowOrder)
        }
    }

    /// Machines whose sessions join the column, by the name ssh knows them under.
    ///
    /// Set in the Settings window; validated on both sides of the store, because
    /// a name becomes an argument to `ssh`. Whoever upgrades from the file-based
    /// version finds the hosts of `~/.lampboard/remotes` imported the first time
    /// this is read — the one write a getter is allowed, and it happens once —
    /// and the file is not consulted again.
    var remoteHosts: [String] {
        get {
            if let stored = defaults.stringArray(forKey: Key.remoteHosts) {
                return stored.filter(RemoteHostList.isUsable)
            }
            let imported = RemoteHostList.parse(
                (try? String(contentsOf: AppConfig.remoteHostsFile, encoding: .utf8)) ?? ""
            )
            defaults.set(imported, forKey: Key.remoteHosts)
            return imported
        }
        nonmutating set {
            var seen = Set<String>()
            defaults.set(
                newValue.map { $0.trimmed }.filter { RemoteHostList.isUsable($0) && seen.insert($0).inserted },
                forKey: Key.remoteHosts
            )
        }
    }

    /// The names the user gave to rows, by folder (`RowNames`).
    var rowNames: [String: String] {
        get { (defaults.dictionary(forKey: Key.rowNames) as? [String: String]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Key.rowNames) }
    }

    /// Rows the user took off the column, by session id, with the moment.
    ///
    /// Kept across restarts because the reason they were removed does not end
    /// when the panel does: a chat tab closed while its process stayed loaded is
    /// still closed tomorrow. Entries older than `sessionStaleAfter` are dropped
    /// on the way in — past that the row would have gone by itself, so the record
    /// is only a way to hide a session somebody may want back.
    var dismissedSessions: [String: Date] {
        get {
            let stored = (defaults.dictionary(forKey: Key.dismissedSessions) as? [String: Double]) ?? [:]
            let horizon = Date().addingTimeInterval(-AppConfig.sessionStaleAfter)
            return stored.compactMapValues { seconds in
                let moment = Date(timeIntervalSince1970: seconds)
                return moment > horizon ? moment : nil
            }
        }
        nonmutating set {
            defaults.set(
                newValue.mapValues(\.timeIntervalSince1970), forKey: Key.dismissedSessions
            )
        }
    }

    /// Projects collected into the summary row, by path.
    var hiddenWorkspaces: Set<String> {
        get { readSet(Key.hiddenWorkspaces) }
        nonmutating set { writeSet(newValue, to: Key.hiddenWorkspaces) }
    }

    /// Projects whose amber dot does not blink, by path.
    var calmBlinkWorkspaces: Set<String> {
        get { readSet(Key.calmBlinkWorkspaces) }
        nonmutating set { writeSet(newValue, to: Key.calmBlinkWorkspaces) }
    }

    /// Rows the user opened to see the sessions inside, by row id.
    ///
    /// By row id and not by folder, because a folder can hold a Claude row and a
    /// Codex row and each is opened on its own. The id already carries both.
    ///
    /// A row stays in here even when its project drops back to a single session.
    /// Opening is a statement about the project, "I want to see inside this one",
    /// not about how many sessions it happens to hold right now: an opening that
    /// evaporated on its own would not come back when a second session started,
    /// and that is the worse surprise.
    var expandedRows: Set<String> {
        get { readSet(Key.expandedRows) }
        nonmutating set { writeSet(newValue, to: Key.expandedRows) }
    }

    /// The order the user put a project's conversations in, by project.
    ///
    /// By session id, and that is the bargain rather than an oversight: a
    /// conversation has no identity that outlives its process, so a place given to
    /// one lasts exactly as long as the conversation. Ids that no longer exist
    /// cost a few bytes and can never be shown again, since none is ever reused.
    var conversationOrder: [String: [String]] {
        get { (defaults.dictionary(forKey: Key.conversationOrder) as? [String: [String]]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Key.conversationOrder) }
    }

    // MARK: - Notifications

    /// `true` when the panel sends system notifications.
    ///
    /// **Off by default**, and not out of generic caution: switching it on makes
    /// the macOS authorization prompt appear, and a prompt should be shown when
    /// somebody has asked for it.
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// Projects that generate no notifications, by path.
    /// It silences the alerts, **never** the color.
    var mutedWorkspaces: Set<String> {
        get { readSet(Key.mutedWorkspaces) }
        nonmutating set { writeSet(newValue, to: Key.mutedWorkspaces) }
    }

    /// Moment until which every notification is suspended.
    var mutedUntil: Date? {
        get {
            let stamp = defaults.double(forKey: Key.mutedUntil)
            guard stamp > 0 else { return nil }
            let date = Date(timeIntervalSince1970: stamp)
            return date > Date() ? date : nil
        }
        nonmutating set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.mutedUntil)
        }
    }

    // MARK: - Integration

    /// `true` when the panel declares your presence at the Mac.
    /// **Off by default**: it inverts a Claude Code behavior.
    var presenceEnabled: Bool {
        get { defaults.bool(forKey: Key.presenceEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.presenceEnabled) }
    }

    /// `true` when the foot of the column shows how much of the account's
    /// allowance is gone.
    ///
    /// **Off by default, and this is the one switch that must stay off.** Every
    /// other thing this app does happens on the Mac; this one asks Anthropic, with
    /// Claude Code's own sign-in, every couple of minutes. That is a promise about
    /// the product — see the README — and a promise is not something to change on
    /// somebody's behalf because the feature is useful.
    var usageEnabled: Bool {
        get { defaults.bool(forKey: Key.usageEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.usageEnabled) }
    }

    /// Whether sessions in folders no editor claims — `claude` in a terminal —
    /// get rows (D25). Off by default: the first click on one asks for an
    /// Automation permission for that terminal application (D8).
    var showsTerminalSessions: Bool {
        get { defaults.bool(forKey: Key.terminalSessions) }
        nonmutating set { defaults.set(newValue, forKey: Key.terminalSessions) }
    }

    /// `true` when the panel is allowed to send messages into sessions.
    ///
    /// **Off by default**, and it is the only feature here whose default is about
    /// safety rather than noise. Delivery works by leaving a file in
    /// `~/.lampboard/inbox/`, and the reader is a shell script Claude Code
    /// spawns — it cannot know who wrote that file. Permissions keep other
    /// accounts out and cannot keep out anything running as you, so while this is
    /// on, any process on your machine can start a turn that speaks in your voice,
    /// with your tools.
    ///
    /// While it is off, the message listener is **not registered at all**: no
    /// hook, no listener, no mailbox. The chat window still reads everything.
    var messageSendingEnabled: Bool {
        get { defaults.bool(forKey: Key.messageSendingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.messageSendingEnabled) }
    }

    // MARK: - Persisted sets

    /// Adds or removes an element from a set, returning the new value.
    /// Preferences are values: they get replaced, not modified in place.
    static func toggling(_ element: String, in set: Set<String>) -> Set<String> {
        set.contains(element) ? set.subtracting([element]) : set.union([element])
    }

    // The arrangement itself lives in `RowOrder`, in Core: deciding where a row
    // goes — and so which project a key addresses — is a domain decision, and
    // decisions that live in the shell are decisions no test can see.

    private func readSet(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func writeSet(_ value: Set<String>, to key: String) {
        // Sorted: keeps the plist readable and any comparison stable.
        defaults.set(value.sorted(), forKey: key)
    }

    /// The remembered edge of the panel: its left, and its **top**.
    ///
    /// The top, because that is the edge every resize holds still, and an
    /// anchor that disagrees with the resize is what walked the panel off the
    /// bottom of the screen a launch at a time. See `PanelPlacement`.
    ///
    /// The old keys held the bottom left. They are not read any more and not
    /// converted either: converting would need the height the panel had when it
    /// was saved, which was never written down. An install that had one comes
    /// back hung off the menu bar, which is where it was trying to get to.
    var savedAnchor: NSPoint? {
        guard defaults.object(forKey: Key.anchorX) != nil,
              defaults.object(forKey: Key.anchorTop) != nil else {
            return nil
        }
        return NSPoint(
            x: defaults.double(forKey: Key.anchorX),
            y: defaults.double(forKey: Key.anchorTop)
        )
    }

    func saveAnchor(_ anchor: NSPoint) {
        defaults.set(anchor.x, forKey: Key.anchorX)
        defaults.set(anchor.y, forKey: Key.anchorTop)
    }

    /// What a screen actually shows, which already excludes the menu bar.
    static func visibleArea(of screen: NSScreen?) -> NSRect {
        (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The frame for a panel of this size, hung where it was left and kept whole
    /// on the screen it is on.
    static func placed(size: NSSize, anchor: NSPoint?, on screen: NSScreen?) -> NSRect {
        let visible = visibleArea(of: screen)
        let hung = anchor.flatMap { candidate -> NSPoint? in
            // A remembered point on a monitor that has been unplugged is not a
            // place. Anything that still lands on a screen is honoured, and the
            // clamp does the rest.
            NSScreen.screens.contains { $0.visibleFrame.contains(candidate) } ? candidate : nil
        } ?? PanelPlacement.defaultAnchor(size: size, in: visible)
        let onScreen = NSScreen.screens.first { $0.visibleFrame.contains(hung) }
        return PanelPlacement.frame(
            hangingFrom: hung, size: size, in: visibleArea(of: onScreen ?? screen)
        )
    }
}
