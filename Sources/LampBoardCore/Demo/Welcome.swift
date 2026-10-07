import Foundation

/// The first minute with LampBoard (U4): seven screens, each with one idea and
/// one action, done on the person's own sessions.
///
/// It replaces three things that did not reach people. The alert of the first
/// launch opened Getting started only when the hooks were installed from its
/// button — the README said to install them from the terminal, and then nothing
/// opened at all. Getting started was nine items of text with the tour as the
/// ninth, under the fold. And the tour played in a second copy of the app. Here
/// every screen's button does what is still missing, and says *Next* once it is
/// done; nothing is learned on invented sessions unless the person asks for the
/// samples.
public enum Welcome {

    /// What the screens need to know about this Mac.
    public struct Facts: Equatable, Sendable {
        public let connected: Bool
        public let codexPresent: Bool
        public let hasRow: Bool
        public let accessibility: Bool
        public let helperInstalled: Bool
        public let alertsOn: Bool

        public init(connected: Bool, codexPresent: Bool, hasRow: Bool, accessibility: Bool,
                    helperInstalled: Bool, alertsOn: Bool) {
            self.connected = connected
            self.codexPresent = codexPresent
            self.hasRow = hasRow
            self.accessibility = accessibility
            self.helperInstalled = helperInstalled
            self.alertsOn = alertsOn
        }
    }

    /// What a screen's main button does.
    public enum Action: Equatable, Sendable {
        case next
        /// Install the hooks; the words name the agents present.
        case connect(String)
        /// Put three sample rows in the panel.
        case practice
        case grantAccessibility
        case installHelper
        case turnOnAlerts
        case close
    }

    public enum Step: Int, CaseIterable, Sendable {
        case welcome, firstLamp, colours, click, answer, search, done

        public var title: String {
            switch self {
            case .welcome: return "See every agent at a glance"
            case .firstLamp: return "Your first lamp"
            case .colours: return "Three colours to know"
            case .click: return "One click and you are there"
            case .answer: return "Answer without changing window"
            case .search: return "⌘K finds everything"
            case .done: return "That's it"
            }
        }

        public var text: String {
            switch self {
            case .welcome:
                return "LampBoard shows one lamp for each coding session, in a column that floats over your work. When a session needs you, its lamp blinks amber."
            case .firstLamp:
                return "Start or restart a Claude Code session: its lamp appears in the panel as soon as it says something. No session at hand? Three sample rows show the panel at work."
            case .colours:
                return "Yellow is working. Green has finished, with an answer to read. Amber is waiting for you, and it is the only thing that blinks. The other colours you will meet when they come."
            case .click:
                return "Click a row: the window of that exact session comes forward. macOS asks once for Accessibility, so the click can choose the right window and not just the app."
            case .answer:
                return "When a session asks «may I run this?», the question can open under its row, with Allow and Deny. It takes the helper, a small Claude Code plugin that talks only to this Mac."
            case .search:
                return "In the panel, ⌘K finds a session, a past conversation, a message to send or a question for LampMaster. A few letters of a project are enough."
            case .done:
                return "LampBoard alerts you only when a session needs you or stops. Everything else is in ⋯ › Settings, when you want it."
            }
        }

        public func action(_ facts: Facts) -> Action {
            switch self {
            case .welcome:
                return facts.connected ? .next : .connect(facts.codexPresent ? "Connect Claude Code and Codex" : "Connect Claude Code")
            case .firstLamp: return facts.hasRow ? .next : .practice
            case .colours, .search: return .next
            case .click: return facts.accessibility ? .next : .grantAccessibility
            case .answer: return facts.helperInstalled ? .next : .installHelper
            case .done: return facts.alertsOn ? .close : .turnOnAlerts
            }
        }
    }
}
