import Foundation

/// One entry of a menu, as data (U3): what the App draws and what each choice does.
///
/// In 1.0 the panel's ⋯ had twenty-three to twenty-five entries in no order, the
/// same switch had three names in three places, and an error message turned up as
/// a menu entry. The menus are now built here, where a test can count them and
/// read their words, and the App only draws what it is given.
public enum MenuEntry: Equatable, Sendable {
    /// A choice: what it does, its words, a check mark when it is a switch that is
    /// on, whether it can be chosen now, and its key with ⌘, if it has one.
    case item(MenuCommand, String, checked: Bool = false, enabled: Bool = true, shortcut: String? = nil)
    case divider
    case submenu(String, [MenuEntry])
    /// A line that says something and does nothing: the lamp's summary.
    case heading(String)
}

/// What a menu entry does. The App maps each one to its action.
public enum MenuCommand: Equatable, Sendable {
    // The panel's ⋯ and the lamp
    case openConversations, legend, capabilities, onlyWaiting, muteForAnHour, resumeAlerts, away, showHidden, settings, quit
    case openPanel, toggleHome
    // A row
    case open, read, sessionView, newConversation, rename, hide
    case dontAlert, dontBlink, focus
    case peek, markUnread, moveUp, moveDown, revealInFinder, pinDecision, unpinDecision(Int), copyAttach, toggleModel
}

/// What the panel's ⋯ needs to know.
public struct PanelMenuState: Equatable, Sendable {
    public let onlyWaiting: Bool
    public let mutedUntil: Date?
    public let isAway: Bool
    public let hiddenCount: Int

    public init(onlyWaiting: Bool, mutedUntil: Date?, isAway: Bool, hiddenCount: Int) {
        self.onlyWaiting = onlyWaiting
        self.mutedUntil = mutedUntil
        self.isAway = isAway
        self.hiddenCount = hiddenCount
    }
}

/// What the lamp's menu needs to know.
public struct LampMenuState: Equatable, Sendable {
    public let wanting: Int
    public let working: Int
    public let home: PanelHome
    public let mutedUntil: Date?
    public let isAway: Bool

    public init(wanting: Int, working: Int, home: PanelHome, mutedUntil: Date?, isAway: Bool) {
        self.wanting = wanting
        self.working = working
        self.home = home
        self.mutedUntil = mutedUntil
        self.isAway = isAway
    }
}

/// What a row's menu needs to know.
public struct RowMenuState: Equatable, Sendable {
    public let isRemote: Bool
    public let compact: Bool
    public let alias: String?
    public let folder: String
    public let status: SessionStatus
    public let isHidden: Bool
    public let isCalm: Bool
    public let isMuted: Bool
    public let isFocused: Bool
    public let notificationsEnabled: Bool
    public let hostsNewConversation: Bool
    /// The repository the row's session works in, for its decision board (D105).
    public let repository: String?
    public let pinned: [String]
    /// What reopens a background session in a terminal (D104).
    public let attachCommand: String?
    /// The governor's offer for the row (G3), in its own words.
    public let modelOffer: String?

    public init(isRemote: Bool, compact: Bool, alias: String?, folder: String, status: SessionStatus,
                isHidden: Bool, isCalm: Bool, isMuted: Bool, isFocused: Bool, notificationsEnabled: Bool,
                hostsNewConversation: Bool, repository: String?, pinned: [String], attachCommand: String?,
                modelOffer: String?) {
        self.isRemote = isRemote
        self.compact = compact
        self.alias = alias
        self.folder = folder
        self.status = status
        self.isHidden = isHidden
        self.isCalm = isCalm
        self.isMuted = isMuted
        self.isFocused = isFocused
        self.notificationsEnabled = notificationsEnabled
        self.hostsNewConversation = hostsNewConversation
        self.repository = repository
        self.pinned = pinned
        self.attachCommand = attachCommand
        self.modelOffer = modelOffer
    }
}

/// The three menus of the panel (U3).
public enum Menus {

    /// The panel's ⋯: the things of every day, and Settings for the rest. Eight
    /// entries, a ninth while some projects are hidden.
    public static func panel(_ state: PanelMenuState, time: (Date) -> String) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(.openConversations, "Open the conversations…"),
            .item(.legend, "What the lights mean…"),
            .item(.capabilities, "What LampBoard can do…"),
            .divider,
            .item(.onlyWaiting, SettingsCatalog.item(.onlyWaiting).label, checked: state.onlyWaiting),
            quiet(mutedUntil: state.mutedUntil, time: time),
            .item(.away, SettingsCatalog.item(.away).label, checked: state.isAway),
        ]
        if state.hiddenCount > 0 {
            entries.append(.item(.showHidden, state.hiddenCount == 1 ? "Show 1 hidden project" : "Show \(state.hiddenCount) hidden projects"))
        }
        entries += [.divider, .item(.settings, "Settings…", shortcut: ","), .item(.quit, "Quit LampBoard")]
        return entries
    }

    /// The lamp in the menu bar: what waits, the panel, the two ways of keeping
    /// quiet, and where the panel lives — the way back out of the menu bar if the
    /// panel ever cannot be opened from it.
    public static func lamp(_ state: LampMenuState, time: (Date) -> String = { _ in "" }) -> [MenuEntry] {
        [
            .heading(summary(wanting: state.wanting, working: state.working)),
            .divider,
            .item(.openPanel, "Open the panel"),
            .item(.openConversations, "Open the conversations…"),
            .divider,
            quiet(mutedUntil: state.mutedUntil, time: time),
            .item(.away, SettingsCatalog.item(.away).label, checked: state.isAway),
            .divider,
            .item(.toggleHome, state.home == .menuBar ? "Put the panel in its own window" : "Put the panel in the menu bar"),
            .item(.settings, "Settings…", shortcut: ","),
            .item(.quit, "Quit LampBoard"),
        ]
    }

    /// A row's menu: eight entries; the ways of keeping it quiet under Quiet, the
    /// rarer things under More.
    public static func row(_ state: RowMenuState) -> [MenuEntry] {
        let local = !state.isRemote
        var entries: [MenuEntry] = [.item(.open, "Open")]
        // The transcript and a new conversation are on this Mac: a row that lives
        // elsewhere is not offered either.
        if local { entries.append(.item(.read, "Read the conversation")) }
        if local, !state.compact { entries.append(.item(.sessionView, "Open in Session view")) }
        if state.hostsNewConversation { entries.append(.item(.newConversation, "New conversation here")) }
        entries.append(.divider)
        entries.append(.item(.rename, state.alias == nil ? "Rename…" : "Rename… (“\(state.folder)” underneath)"))
        entries.append(.item(.hide, "Hide", checked: state.isHidden))
        entries.append(.submenu("Quiet", quietEntries(state)))
        entries.append(.submenu("More", moreEntries(state)))
        return entries
    }

    // MARK: - Pieces

    /// «2 waiting · 3 working», with the zeros said in words.
    public static func summary(wanting: Int, working: Int) -> String {
        let waits = wanting == 0 ? "Nothing waiting" : "\(wanting) waiting"
        let works = working == 0 ? "nothing at work" : "\(working) working"
        return waits + " · " + works
    }

    private static func quiet(mutedUntil: Date?, time: (Date) -> String) -> MenuEntry {
        if let mutedUntil { return .item(.resumeAlerts, "Resume alerts (muted until \(time(mutedUntil)))") }
        return .item(.muteForAnHour, "Mute alerts for an hour")
    }

    private static func quietEntries(_ state: RowMenuState) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if state.notificationsEnabled { entries.append(.item(.dontAlert, "Don't alert me", checked: state.isMuted)) }
        if state.status == .awaiting { entries.append(.item(.dontBlink, "Don't blink", checked: state.isCalm)) }
        entries.append(.item(.focus, "Focus on this session", checked: state.isFocused))
        return entries
    }

    private static func moreEntries(_ state: RowMenuState) -> [MenuEntry] {
        var entries: [MenuEntry] = [.item(.peek, "Open without marking as read")]
        if state.status == .idle { entries.append(.item(.markUnread, "Mark as unread")) }
        entries += [.item(.moveUp, "Move up"), .item(.moveDown, "Move down")]
        if !state.isRemote { entries.append(.item(.revealInFinder, "Show in Finder")) }
        if !state.isRemote, let repository = state.repository {
            entries.append(.item(.pinDecision, "Pin a decision for “\(repository)”…"))
            if !state.pinned.isEmpty {
                entries.append(.submenu("Pinned decisions (\(state.pinned.count))", state.pinned.enumerated().map { index, text in
                    .item(.unpinDecision(index + 1), "Take off: \(text)")
                }))
            }
        }
        if let attach = state.attachCommand { entries.append(.item(.copyAttach, "Copy “\(attach)”")) }
        if let offer = state.modelOffer { entries.append(.item(.toggleModel, offer)) }
        return entries
    }
}
