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
        public var mod = false
        public var permissionsFromPanel = false
        public var sending = false
        public var tourFinished = false
        public var renamed = false
        public var reordered = false
        public var answeredLampMaster = false
        public var askedFromSession = false
        public var askedFromPanel = false

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
            Item(id: "send", title: "Write to a session from the panel",
                 detail: "From the Plancia or the bar (@name message), into the session's own box, as you. Needs the "
                    + "hooks. Asking it a side question without adding a turn (@name ?question) needs the mod too.",
                 done: facts.sending && facts.hooks, optional: true),
            Item(id: "mod", title: "The LampBoard mod, for exact figures and answers from the panel",
                 detail: "A small plugin inside each Claude Code session (2.1.287 and later). It tells the panel its "
                    + "context, cost and limits as Claude Code counts them, and which tool it is running. It never "
                    + "runs a tool or writes a file itself, and talks only to this Mac. It can make Claude Code ask "
                    + "you first: before an edit to a file another session just wrote, and while you are away, before "
                    + "a destructive command. It answers a side question or a handoff from the session's conversation, "
                    + "read again from cache, and lowers a session's model when you ask the panel to. Settings shows "
                    + "what Claude Code reads in it.",
                 done: facts.mod, optional: true),
            Item(id: "answer-from-panel", title: "Answer permissions from the panel",
                 detail: "Needs the mod. A permission waits at the top of the panel with Allow and Deny, and says what "
                    + "the call would do; a question Claude asks you waits there with its options. Unanswered — 55 "
                    + "seconds for a permission, 20 for a question — it goes back to the session's own dialog.",
                 done: facts.permissionsFromPanel && facts.mod, optional: true),
            Item(id: "notifications", title: "Notifications, if you want them",
                 detail: "A notification when a session asks for permission, asks you a question, or fails — "
                    + "and for a finished turn only if you ask for it in Settings.",
                 done: facts.notifications, optional: true),
            Item(id: "lampmaster", title: "LampMaster, if you want it",
                 detail: "Once an hour a model reads your sessions and suggests at most three things. It sends "
                    + "pieces of your conversations to Anthropic and spends your allowance: off until you say so.",
                 done: facts.lampMaster, optional: true),
            Item(id: "callable", title: "Let your sessions ask LampMaster",
                 detail: "Adds the lampmaster MCP server to Claude Code, so a session can ask who else is on its "
                    + "files or who solved an error before.",
                 done: facts.lampMasterCallable, optional: true),
            Item(id: "tour", title: "Take the tour",
                 detail: "A second panel with invented sessions, none of them yours: twelve steps, each done by "
                    + "doing it, from the colours to asking LampMaster.",
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
            Item(id: "ask-panel", title: "Ask LampMaster about all your sessions",
                 detail: "⌘K, then ?which session renamed the slots endpoint — or the box on its Plancia's Today. "
                    + "A follow-up is read against the answer before.",
                 done: facts.askedFromPanel, optional: !facts.lampMaster),
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
