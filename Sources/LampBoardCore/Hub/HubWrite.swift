import Foundation

/// How the Hub writes to a session (D154): one rule in one place, so every
/// control that sends asks it and none decides on its own.
///
/// A session has one writer — the person, through whatever they type in — and
/// the Hub adds ways in only where the order of what arrives is known:
/// - **mod**: the companion mod's `$.prompt.submit`, signed (D152). Measured
///   (10 October 2026): it waits for a running turn and for a dialog, and
///   leaves a draft in the box as it is.
/// - **box**: Claude Code's message box (D81), taken into a running turn.
/// - **paste**: typed into the session's tmux pane, behind the gate of D147
///   (Claude there, nothing asked, the pane attached).
/// - **none**: read only; the Hub offers the real window instead.
public enum HubWrite {

    public enum Route: String, Equatable, Sendable {
        case mod, box, paste, none
    }

    /// What Send does (Marco's choice, 10 October 2026, as Hermes does it).
    public enum Mode: String, CaseIterable, Equatable, Sendable {
        /// Stop the turn running, then send: the session reads it now.
        case interrupt
        /// After the turn: the session reads it when it is free.
        case queue
        /// Into the running turn, as a message beside it.
        case steer
    }

    /// What the Hub knows of the session's own message box (D154).
    public enum Presence: String, Equatable, Sendable {
        /// Nothing typed there, or a terminal without the mod, which the live
        /// view already writes to as it is (D147).
        case empty
        /// The person has typed something there and not sent it.
        case draft
        /// A box LampBoard cannot see: VS Code's panel, the Claude app.
        case unseen
    }

    /// The presence for a session: its mod's surface, else how it was started,
    /// and the mod's last word on the draft.
    public static func presence(surface: String?, entrypoint: String?, draft: Bool?) -> Presence {
        if let surface, surface != "terminal" { return .unseen }
        if surface == nil, ["claude-vscode", "claude-desktop"].contains(entrypoint ?? "") { return .unseen }
        return draft == true ? .draft : .empty
    }

    /// What the Hub knows of a session when the person presses Send.
    public struct Situation: Equatable, Sendable {
        /// The session's mod says it takes signed commands.
        public var commands: Bool
        /// The session has a message box this panel can reach.
        public var box: Bool
        /// The session runs in a tmux pane the panel can type into, gate open.
        public var paste: Bool
        /// A turn is running.
        public var busy: Bool
        /// A dialog waits for the person (a permission, a question).
        public var asking: Bool
        /// What the session's own box holds.
        public var presence: Presence

        public init(commands: Bool, box: Bool, paste: Bool, busy: Bool, asking: Bool, presence: Presence = .empty) {
            self.commands = commands
            self.box = box
            self.paste = paste
            self.busy = busy
            self.asking = asking
            self.presence = presence
        }
    }

    /// What Send does in a situation: the way in, the mode it goes in, whether
    /// to ask first, and the band to show.
    public struct Verdict: Equatable, Sendable {
        public let route: Route
        public let mode: Mode
        /// The person is typing in the session's own box: ask before sending.
        public let confirm: Bool
        public let band: String?
    }

    /// The one decision every Send goes through (D154).
    ///
    /// - A box LampBoard cannot see only queues: stopping a turn someone may be
    ///   watching in VS Code is theirs to do there.
    /// - A draft is never pasted into, and is asked about otherwise: the
    ///   message goes first and the draft stays where it is (measured, M0).
    public static func verdict(_ mode: Mode, in situation: Situation) -> Verdict {
        let unseen = situation.presence == .unseen
        let effective: Mode = unseen ? .queue : mode
        var way = route(effective, in: situation)
        if way == .paste, situation.presence == .draft { way = .none }
        return Verdict(
            route: way, mode: effective,
            confirm: way != .none && situation.presence == .draft,
            band: unseen ? "LampBoard cannot see this session's own message box: messages wait for the turn to end." : nil
        )
    }

    /// Whether a sent message has reached the transcript: one more user
    /// message with its words than when it was sent (D154's receipt).
    public static func arrived(_ sent: String, before: [String], now: [String]) -> Bool {
        let key = words(sent)
        return now.filter { words($0) == key }.count > before.filter { words($0) == key }.count
    }

    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The route for `mode` in `situation`.
    ///
    /// - Steering needs a message taken into a running turn, which only the box
    ///   does; with no turn running it is the same as queueing.
    /// - The mod queues and interrupts; it also waits for a dialog by itself.
    /// - The box and the paste are the fallbacks, never over a dialog: a pasted
    ///   line or a box message would answer it or be lost behind it.
    public static func route(_ mode: Mode, in situation: Situation) -> Route {
        if mode == .steer, situation.busy {
            if situation.box, !situation.asking { return .box }
            return situation.commands ? .mod : .none
        }
        if situation.commands { return .mod }
        if situation.asking { return .none }
        if situation.box { return .box }
        if situation.paste, !situation.busy { return .paste }
        return .none
    }

    /// The command arguments the mod reads for a message (`inbox.js`): the
    /// person's own words (`asUser`), and whether to stop the turn first.
    public static func submitArgs(text: String, mode: Mode) -> [String: String] {
        ["text": text, "asUser": "true", "mode": mode == .interrupt ? "interrupt" : "queue"]
    }

    /// The longest message the Hub sends, like the box's (D15).
    public static let maxBytes = 64 * 1024

    /// The text trimmed, or `nil` when there is nothing to send or too much.
    public static func sendable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }

    /// The end of a reply being written, as the live bubble shows it: the last
    /// `lines` lines, each cut from the left to 200 characters. Bounded whatever
    /// the reply's size, so a piece costs the same at the first line and the
    /// thousandth (P1).
    public static func tail(of full: String, lines: Int) -> String {
        full.suffix(4_000).split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).map { $0.count > 200 ? "…" + $0.suffix(199) : String($0) }
            .joined(separator: "\n")
    }
}
