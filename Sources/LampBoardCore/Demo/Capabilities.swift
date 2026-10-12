import Foundation

/// What LampBoard can do, by what a person wants rather than by component (U5).
///
/// In 1.0 the strong features were behind switches and commands nobody met: the
/// answers from the panel, the safety catch, the lighter model, the pinned
/// decisions. The catalogue puts each one in a sentence, says whether it needs the
/// helper, and offers to try it, to turn it on, or where to find it.
public enum Capabilities {

    /// A gesture the catalogue can start for you.
    public enum TryIt: Equatable, Sendable {
        /// Opens the bar with these characters typed.
        case bar(String)
        case samples
        case legend
    }

    public struct Item: Equatable, Sendable {
        public let name: String
        public let sentence: String
        public let needsHelper: Bool
        /// The switch in Settings that turns it on.
        public let setting: SettingsCatalog.ID?
        public let tryIt: TryIt?
        /// Where it is, when it is a gesture rather than a switch.
        public let place: String
    }

    public struct Group: Equatable, Sendable {
        public let title: String
        public let items: [Item]
    }

    private static func item(_ name: String, _ sentence: String, helper: Bool = false, setting: SettingsCatalog.ID? = nil,
                             tryIt: TryIt? = nil, place: String = "") -> Item {
        Item(name: name, sentence: sentence, needsHelper: helper, setting: setting, tryIt: tryIt, place: place)
    }

    public static let groups: [Group] = [
        Group(title: "Answer sooner", items: [
            item("Quick answers", "Allow or Deny a permission from the panel, without changing window.", helper: true, setting: .answerPrompts),
            item("Quick question", "Ask a session something without interrupting it: @name ?question in ⌘K.", helper: true, tryIt: .bar("@")),
            item("Write to a session", "@name message in ⌘K: it waits in the session's terminal in the Hub, for you to send.", setting: .sendMessages, tryIt: .bar("@")),
        ]),
        Group(title: "Stay out of trouble", items: [
            item("Safety catch", "While you are away, commands that delete, force-push or discard wait for you.", helper: true, setting: .safetyCatch),
            item("File clash warning", "Asked first when a session edits a file another one has just written.", helper: true,
                 place: "A ⚠ beside the row's name"),
            item("Stuck mark", "A dashed yellow lamp: one command has been running for a quarter of an hour.", tryIt: .legend),
            item("Context left", "The ring beside each lamp: how full the conversation is, and on which model.", tryIt: .legend),
        ]),
        Group(title: "Spend less", items: [
            item("Usage left and forecast", "When your window runs out at this pace, and when it comes back.", setting: .usage),
            item("Save usage", "One session on a lighter model until the window resets.", helper: true,
                 place: "A row's menu › More › Use Sonnet until the window resets"),
        ]),
        Group(title: "Work across sessions", items: [
            item("LampMaster", "The reviewer: a look at every session once an hour, three suggestions at most.", setting: .lampMaster),
            item("Ask LampMaster", "«who renamed the slots endpoint?», with follow-ups.", tryIt: .bar("?")),
            item("Project rules", "One decision, and every session in the repository keeps to it.", helper: true,
                 place: "A row's menu › More › Add a project rule"),
            item("Hand over", "Pass what one session knows to another.", tryIt: .bar("/handoff @")),
            item("The Hub", "Each session in its own terminal, Claude Code itself; the project's files beside it; the sessions in VS Code read.",
                 setting: .liveOpensBackground, place: "The Hub button at the panel's foot, ⌘⇧L, or a row's menu › Open in the Hub"),
            item("Projects", "A folder here or on another machine, kept in the Hub: start a session there, or take up a past one.",
                 place: "The Hub › Projects › +"),
            item("New session", "Starts Claude Code in a folder, in tmux, on this Mac or on another machine, and opens it in the Hub.",
                 place: "The panel's ⋯ › New session…"),
        ]),
        Group(title: "Step away", items: [
            item("I'm away", "Nothing interrupts; back, one line says what the rows no longer show.", setting: .away),
            item("Focus", "One session in front; the others wait their turn to alert you.",
                 place: "A row's menu › Quiet › Focus on this session"),
            item("Spoken alerts", "Hear «api is waiting for you» from across the room.", setting: .speak),
            item("Alerts", "Only when a session needs you or stops.", setting: .notifications),
        ]),
        Group(title: "Look back and far", items: [
            item("Search every conversation", "Find the conversation where you decided it. Ninety days, all on this Mac.",
                 setting: .searchIndex, tryIt: .bar("")),
            item("This week", "Prompts, projects, and how long sessions waited for you.", tryIt: .bar("week")),
            item("Other machines", "Sessions on another computer as rows, over your own ssh.", setting: .otherMacs),
            item("Background sessions", "Claude Code's sessions without a terminal are rows too.", place: "On by itself"),
        ]),
    ]
}
