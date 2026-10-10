import Foundation

/// Every setting LampBoard has, where it lives and what it is called (U3).
///
/// In 1.0 the switches were in four places — the panel's ⋯, the Settings window,
/// Getting started and a row's menu — and one switch had three names in three of
/// them. They are now in one window of nine sections, each with a line under it
/// saying what it does, and a menu that offers a switch uses the name it has here.
/// The window draws from this list; the words live nowhere else.
public enum SettingsCatalog {

    public enum ID: String, Sendable, CaseIterable {
        case home, lampInMenuBar, menuBarCounter
        case width, onlyWaiting, terminalSessions, hiddenProjects
        case launchAtLogin
        case accessibility, sessionTab, barShortcut
        case liveOpensBackground, liveTheme, liveFontSize, liveLook, liveFontFamily, liveLineSpacing, liveLetterSpacing, liveOpensChat, liveCustomColors
        case notifications, notifyFinished, speak
        case mute, away, silenced
        case presence
        case connection, helper, band
        case sendMessages, answerPrompts, safetyCatch
        case lampMaster, lampMasterEvery, lampMasterModel, lampMasterAsk, lampMasterMuted
        case otherMacs
        case usage, updates, searchIndex
        case version, gettingStarted, samples, capabilities, legend, clearList
    }

    public struct Item: Equatable, Sendable {
        public let id: ID
        public let label: String
        public let help: String
    }

    public struct Group: Equatable, Sendable {
        /// Empty for a section of one group.
        public let title: String
        public let items: [Item]
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        /// What is here acts on the sessions or sends something off this Mac:
        /// drawn with an orange edge.
        public let warns: Bool
        public let groups: [Group]
    }

    public static func item(_ id: ID) -> Item {
        sections.lazy.flatMap { $0.groups.flatMap(\.items) }.first { $0.id == id }!
    }

    public static func section(of id: ID) -> Section {
        sections.first { $0.groups.contains { $0.items.contains { $0.id == id } } }!
    }

    private static func i(_ id: ID, _ label: String, _ help: String) -> Item { Item(id: id, label: label, help: help) }

    public static let sections: [Section] = [
        Section(title: "Panel", warns: false, groups: [
            Group(title: "Where it lives", items: [
                i(.home, "Panel lives in", "In its own window above the others, or under the lamp in the menu bar, opened by a click."),
                i(.lampInMenuBar, "Show a lamp in the menu bar", "Always there while the panel lives in the menu bar: nothing else could bring it back."),
                i(.menuBarCounter, "Count beside the lamp", "How many sessions want you · how many are at work."),
            ]),
            Group(title: "What it shows", items: [
                i(.width, "Width", ""),
                i(.onlyWaiting, "Show only what's waiting", "Rows that want nothing from you step aside, and a line says how many."),
                i(.terminalSessions, "Show sessions started in a terminal", "A claude started in a terminal gets a row of its own. Clicking one asks once per terminal app for Automation."),
                i(.hiddenProjects, "Hidden projects", "Projects you hid from the column. The «hidden» line still lights up when one of them needs you."),
            ]),
            Group(title: "Startup", items: [
                i(.launchAtLogin, "Open at login", "LampBoard starts when you log in."),
            ]),
        ]),
        Section(title: "Clicks & keys", warns: false, groups: [
            Group(title: "", items: [
                i(.accessibility, "Accessibility", "Lets a click bring the right editor window forward, not just the app."),
                i(.sessionTab, "Also open the conversation's tab in VS Code", "VS Code asks you to confirm every time."),
                i(.barShortcut, "Search bar from any app", "Inside the panel ⌘K always works. Off by default: ⌘K alone would take shortcuts VS Code begins with."),
            ]),
            Group(title: "The live view", items: [
                i(.liveOpensBackground, "Open here when LampBoard can", "A click on a session in the background, or in tmux on this Mac or another, opens it in a LampBoard window instead of jumping. Sessions in an editor still jump. Closing the window leaves the session running."),
                i(.liveOpensChat, "Open on the chat", "A live window shows the conversation as a chat, in an ordinary font, with a box to write in; its terminal keeps running under it, a click away."),
                i(.liveTheme, "Look", "The window around the session. Claude Code keeps its own colours inside, except with the VS Code themes; Like my VS Code reads the colours of the VS Code on this Mac."),
                i(.liveFontSize, "Text size", "The size of the session's text, in every live window at once."),
                i(.liveCustomColors, "Colours", "With Look set to Custom: the background and the text, picked freely; the frame and the chat follow them."),
                i(.liveFontFamily, "Font", "Any fixed-width font on this Mac: Claude Code draws on a grid, which a proportional font would break."),
                i(.liveLetterSpacing, "Letter spacing", "Tighter letters read more like an ordinary font; below 85% the wide ones touch."),
                i(.liveLineSpacing, "Line spacing", "A little air between lines reads like a chat; too much splits Claude Code's boxes."),
                i(.liveLook, "Claude Code's look", "The conversation drawn like Claude Code's VS Code panel: framed prompts, one line per tool, framed diffs, checklists. By the helper, in LampBoard's windows, in every terminal, or nowhere."),
            ]),
        ]),
        Section(title: "Alerts", warns: false, groups: [
            Group(title: "Notifications", items: [
                i(.notifications, "Notify me when a session waits for me or fails", "Only these two, saying what it asks or why it stopped."),
                i(.notifyFinished, "Also when a turn finishes", "With the first line of the answer."),
                i(.speak, "Say it aloud when I'm away from the keys", "After a minute without a key, screen unlocked. Never while you are away, muted or in focus."),
            ]),
            Group(title: "Quiet", items: [
                i(.mute, "Mute all alerts", "For an hour. The rows still change colour."),
                i(.away, "I'm away", "Also on after three minutes of locked screen. Back, one line says what the rows no longer show."),
                i(.silenced, "Projects you've silenced", "Set from a row's Quiet menu: no alerts, or no blinking."),
            ]),
            Group(title: "Your phone", items: [
                i(.presence, "Skip Claude Code's phone pushes while I'm at this Mac", "Claude Code reads a file LampBoard keeps while you are here. If the detection is wrong, a push is lost, not doubled."),
            ]),
        ]),
        Section(title: "Claude Code & Codex", warns: false, groups: [
            Group(title: "Connection", items: [
                i(.connection, "Connected agents", "A few lines in Claude Code's and Codex's settings, with a backup, through which each session tells the panel what it is doing."),
            ]),
            Group(title: "The LampBoard helper", items: [
                i(.helper, "Install the LampBoard helper", "A small Claude Code plugin: exact context and cost, answers from the panel, the safety catch. Talks only to this Mac."),
                i(.band, "Show what waits elsewhere above each prompt", "One line above the prompt of the other sessions, in the terminal and the Claude app. Not in VS Code."),
            ]),
        ]),
        Section(title: "Acting from the panel", warns: true, groups: [
            Group(title: "These act on your sessions", items: [
                i(.sendMessages, "Send messages to sessions", "Write to a session from ⌘K or its Session view. Anything running as you could then start a turn in your name: asks before it turns on."),
                i(.answerPrompts, "Answer permission prompts and questions", "Needs the helper. Up to 55 seconds for a permission, 20 for a question, then the session asks as usual."),
                i(.safetyCatch, "Safety catch while I'm away", "With the helper, a command that deletes recursively, force-pushes, discards changes or runs as root waits for you. A fixed list of spellings, not a sandbox."),
            ]),
        ]),
        Section(title: "LampMaster", warns: true, groups: [
            Group(title: "The reviewer", items: [
                i(.lampMaster, "Let LampMaster suggest", "Reads this Mac's sessions once an hour and suggests at most three things. Sends parts of your conversations to Anthropic with your own sign-in."),
                i(.lampMasterEvery, "Check every", "A round with nothing new costs nothing."),
                i(.lampMasterModel, "Model", "Opus finds the links between sessions; Sonnet is faster and cheaper."),
                i(.lampMasterAsk, "Let sessions ask LampMaster", "Adds the lampmaster tool to Claude Code, for all your projects."),
                i(.lampMasterMuted, "Suggestions you turned off", "Kinds you asked not to see again, and the way to bring them back."),
            ]),
        ]),
        Section(title: "Other Macs", warns: false, groups: [
            Group(title: "Machines over ssh", items: [
                i(.otherMacs, "Machines", "Their sessions appear as rows, through a tunnel over your own ssh. The machine needs key login, python3 and curl."),
            ]),
        ]),
        Section(title: "Privacy & data", warns: false, groups: [
            Group(title: "What leaves this Mac", items: [
                i(.usage, "Usage left", "Asks Anthropic how much of your plan is left, with your Claude Code sign-in."),
                i(.updates, "Update check", "Only when you ask, from About & help."),
            ]),
            Group(title: "On this Mac", items: [
                i(.searchIndex, "Keep a search index of my conversations", "Local, no tokens, the last 90 days: what ⌘K and LampMaster search."),
            ]),
        ]),
        Section(title: "About & help", warns: false, groups: [
            Group(title: "", items: [
                i(.version, "LampBoard", "Signed and notarized. MIT licence."),
                i(.gettingStarted, "Getting started", "The seven first screens again: connecting, the colours, the click, answering, ⌘K."),
                i(.capabilities, "What LampBoard can do", "Every capability in a sentence, with Try and Turn on."),
                i(.samples, "Practice with samples", "Three invented rows in your panel, marked as samples, removed with one click."),
                i(.legend, "What the lights mean", "The colours and rings of the column, with how many of each there are now."),
                i(.clearList, "Clear the list", "Empties the column. Asks first; a session comes back with its next signal."),
            ]),
        ]),
    ]
}
