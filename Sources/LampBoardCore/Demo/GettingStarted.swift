import Foundation

/// What "Getting started" lists, and what is already done.
///
/// Two lists. The preparation is the real setup — what LampBoard installs, the
/// permission it asks for, the switches that send something off the Mac — each
/// item explained before its button. The first steps are the gestures worth
/// trying on one's own sessions. Every tick is read from the state the panel
/// already keeps, so nothing new is recorded about anybody and an item is done
/// when it is, wherever it was done from.
public enum GettingStarted {

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let done: Bool
        /// Optional items never count against "remaining".
        public let optional: Bool
    }

    /// What the panel can tell about this Mac today.
    public struct Facts: Equatable, Sendable {
        public var hooks = false
        public var accessibility = false
        public var notifications = false
        public var lampMaster = false
        public var lampMasterCallable = false
        public var tourFinished = false
        public var renamed = false
        public var reordered = false
        public var answeredLampMaster = false
        public var askedFromSession = false

        public init() {}
    }

    public static func preparation(_ facts: Facts) -> [Item] {
        [
            Item(id: "hooks", title: "Connect Claude Code and Codex",
                 detail: "LampBoard adds hooks to ~/.claude/settings.json and Codex's hooks.json, with a backup, "
                    + "and touches nothing else there. lampboard uninstall-hooks takes them out.",
                 done: facts.hooks, optional: false),
            Item(id: "accessibility", title: "Let a click bring the window forward",
                 detail: "The Accessibility permission lets LampBoard raise the exact editor window of a session. "
                    + "Without it a click opens the editor but cannot choose the window.",
                 done: facts.accessibility, optional: false),
            Item(id: "notifications", title: "Notifications, if you want them",
                 detail: "A notification when a session asks for permission, asks you a question, or fails — "
                    + "never for a session that simply finished.",
                 done: facts.notifications, optional: true),
            Item(id: "lampmaster", title: "LampMaster, if you want it",
                 detail: "Once an hour a model reads your sessions and suggests at most three things. It sends "
                    + "pieces of your conversations to Anthropic and spends your allowance: off until you say so.",
                 done: facts.lampMaster, optional: true),
            Item(id: "callable", title: "Let your sessions ask LampMaster",
                 detail: "Adds the lampmaster MCP server to Claude Code, so a session can ask who else is on its "
                    + "files or who solved an error before.",
                 done: facts.lampMasterCallable, optional: true),
            Item(id: "tour", title: "Take the three-minute tour",
                 detail: "A second panel with invented sessions, none of them yours, shows what every colour means.",
                 done: facts.tourFinished, optional: true),
        ]
    }

    public static func firstSteps(_ facts: Facts) -> [Item] {
        [
            Item(id: "rename", title: "Give a row the name you read it by",
                 detail: "Right-click a row › Rename. The folder keeps its name; only the panel's changes.",
                 done: facts.renamed, optional: false),
            Item(id: "reorder", title: "Put the rows in your order",
                 detail: "Drag a row by its handle. The column never reorders itself, so lampboard open 3 always "
                    + "means the same project.",
                 done: facts.reordered, optional: false),
            Item(id: "answer", title: "Answer one of LampMaster's cards",
                 detail: "Open, Ignore or Wrong: each answer teaches it what is worth your time.",
                 done: facts.answeredLampMaster, optional: !facts.lampMaster),
            Item(id: "ask", title: "Ask LampMaster from a session",
                 detail: "In any session: \"ask lampmaster who else is working on this file\".",
                 done: facts.askedFromSession, optional: !facts.lampMasterCallable),
        ]
    }

    /// Items still to do that are not optional, across both lists.
    public static func remaining(_ facts: Facts) -> Int {
        (preparation(facts) + firstSteps(facts)).filter { !$0.done && !$0.optional }.count
    }
}
