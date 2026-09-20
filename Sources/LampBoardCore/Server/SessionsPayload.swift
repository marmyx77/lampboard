import Foundation

/// A session as seen by whoever queries the read endpoint.
///
/// Deliberately a separate type from `SessionState`: the format leaving the app
/// is a contract with the outside world, and tying it to the internal structure
/// would turn every refactor into a breaking change for its consumers.
public struct SessionSnapshot: Sendable, Equatable, Codable {
    public let id: String
    public let status: String
    public let workspace: String
    public let path: String
    public let updatedAt: Date
    public let statusSince: Date
    public let activeSubagents: Int

    /// Which coding agent the session belongs to. Exposed because a reader of
    /// this endpoint has the same question a reader of the panel has: whether a
    /// green row is one that could have turned red.
    public let harness: String

    /// What a blocked session is asking for, when its harness says. `nil` on a
    /// row that is not blocked, and on every Claude Code row — see `PendingAsk`.
    public let pendingAsk: String?

    /// What a `waiting` session is waiting on — `monitor`, `shell`, `subagent` —
    /// in Claude Code's order. Empty unless the status is `waiting`. A reader that
    /// shows a blue dot without this cannot tell a CI wait from a forgotten server.
    public let waitingOn: [String]
    /// How full the session's context was at its last reply, as a percentage —
    /// and how much that figure can be trusted.
    ///
    /// Three fields rather than one number, because one number would be read as
    /// "how full it is now" and it is not: only assistant records carry a token
    /// count, so anything loaded since the last reply is invisible.
    /// `contextConfidence` is `exact`, `floor` or `unknown`, and a reader that
    /// shows the percentage without it is publishing a figure measured, once, at
    /// seventeen times too small.
    ///
    /// All three are absent for a session that has never answered, one on a
    /// machine that could not be asked, and a model whose window is not
    /// recorded.
    public let contextPercent: Int?
    public let contextTokens: Int?
    public let contextWindow: Int?
    public let contextModel: String?
    public let contextConfidence: String?

    public let failureReason: String?
    public let lastMessage: String?
    public let muted: Bool

    /// The keyboard slot this project is bound to — its position in the user's
    /// order, 1-based, for the first nine — or `nil`.
    ///
    /// Part of the read contract because it answers a question no consumer can
    /// work out on its own: the order lives in the preferences, not in anything
    /// Claude Code reports.
    public let slot: Int?

    /// Absolute path of the session's JSONL transcript, when one is known.
    ///
    /// Published because it is the one field that turns this endpoint from a
    /// status feed into something you can build a reader on: everything else says
    /// how a session **is**, this says where to find what was **said**.
    public let transcriptPath: String?

    /// The repository and branch the session started in, when the hook script
    /// could resolve them. Carried so that a remote node's rows say it too.
    public let git: GitIdentity?

    /// The machine the session runs on, as configured in the settings; `nil` for
    /// this one. A reader that raises windows needs it: there is nothing local to raise.
    public let host: String?

    /// How the session was started, as Claude Code reports it: `claude-vscode`
    /// for one the extension hosts, `cli` for `claude` typed in a terminal.
    /// `nil` when nothing has said yet.
    ///
    /// Published because it is the fact that separates a session with a tab
    /// from one without: a reader that opens tabs needs it as much as the click.
    public let entrypoint: String?

    /// `editor` for a session an editor window hosts, `terminal` for one whose
    /// folder nobody claims and whose place is a terminal tab. A reader that
    /// raises windows must not look for an editor window of a terminal row.
    public let origin: String

    /// The conversation's title, once the transcript has one. What names a
    /// terminal row; informative for the others.
    public let title: String?

    /// What the panel calls the session's row: the name the user gave the
    /// folder, or the conversation title for a lone terminal row, or the
    /// folder. `workspace` stays the folder — the key everything is found by.
    public let label: String

    public init(
        id: String,
        status: String,
        workspace: String,
        path: String,
        updatedAt: Date,
        statusSince: Date,
        activeSubagents: Int = 0,
        harness: String = Harness.claudeCode.rawValue,
        pendingAsk: String? = nil,
        waitingOn: [String] = [],
        contextPercent: Int? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        contextModel: String? = nil,
        contextConfidence: String? = nil,
        failureReason: String? = nil,
        lastMessage: String? = nil,
        muted: Bool = false,
        slot: Int? = nil,
        transcriptPath: String? = nil,
        git: GitIdentity? = nil,
        host: String? = nil,
        entrypoint: String? = nil,
        origin: String = SessionOrigin.editor.rawValue,
        title: String? = nil,
        label: String? = nil
    ) {
        self.contextPercent = contextPercent
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextModel = contextModel
        self.contextConfidence = contextConfidence
        self.id = id
        self.status = status
        self.workspace = workspace
        self.path = path
        self.updatedAt = updatedAt
        self.statusSince = statusSince
        self.activeSubagents = activeSubagents
        self.harness = harness
        self.pendingAsk = pendingAsk
        self.waitingOn = waitingOn
        self.failureReason = failureReason
        self.lastMessage = lastMessage
        self.muted = muted
        self.slot = slot
        self.transcriptPath = transcriptPath
        self.git = git
        self.host = host
        self.entrypoint = entrypoint
        self.origin = origin
        self.title = title
        self.label = label?.trimmed.nilIfEmpty ?? workspace
    }
}

/// Body of the `GET /sessions` response.
public struct SessionsResponse: Sendable, Equatable, Codable {
    public let generatedAt: Date
    public let sessions: [SessionSnapshot]

    public init(generatedAt: Date, sessions: [SessionSnapshot]) {
        self.generatedAt = generatedAt
        self.sessions = sessions
    }
}

/// Serializes and deserializes the body of the read endpoint.
///
/// Dates travel as ISO 8601: a numeric timestamp would force every consumer to
/// guess the unit, and one that guesses wrong doesn't find out until it looks at
/// a time that is fifty years off.
public enum SessionsCodec {

    public static func encode(_ response: SessionsResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys: makes comparing two responses a readable diff instead of a
        // random reshuffle.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response)
    }

    public static func decode(_ data: Data) throws -> SessionsResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionsResponse.self, from: data)
    }

    /// Builds the snapshot of a session.
    ///
    /// - Parameter slot: the keyboard slot of the session's project, if it holds
    ///   one of the first nine places in the column.
    /// - Parameter alias: the name the user gave the session's folder, if any.
    public static func snapshot(
        of session: SessionState,
        muted: Bool = false,
        slot: Int? = nil,
        alias: String? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: session.id,
            status: session.status.rawValue,
            workspace: session.workspace.name,
            path: session.workspace.path,
            updatedAt: session.updatedAt,
            statusSince: session.statusSince,
            activeSubagents: session.activeSubagents,
            harness: session.harness.rawValue,
            pendingAsk: session.pendingAsk?.sentence,
            waitingOn: session.waitingOn,
            contextPercent: session.context?.percent,
            contextTokens: session.context?.tokens,
            contextWindow: session.context?.window,
            contextModel: session.context?.model,
            contextConfidence: session.context?.confidence.rawValue,
            failureReason: session.failureReason?.rawValue,
            lastMessage: session.lastMessage,
            muted: muted,
            slot: slot,
            transcriptPath: session.transcriptPath,
            git: session.git,
            host: session.workspace.host,
            entrypoint: session.entrypoint,
            origin: session.origin.rawValue,
            title: session.title,
            label: alias ?? session.displayName
        )
    }
}
