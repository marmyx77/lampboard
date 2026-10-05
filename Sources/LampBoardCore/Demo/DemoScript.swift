import Foundation

/// The invented sessions the tutorial, the screenshots and the site's demo are
/// played from: one place for demo data, so one place to check that it holds
/// nothing real.
///
/// A script is beats in time. Each beat is a hook payload, the same JSON the
/// installed hooks send, so the trial panel reaches its states through the
/// same server and the same reducer as the real one: a colour the tutorial
/// shows is a colour the panel really produces.
public struct DemoScript: Codable, Sendable, Equatable {

    public struct Session: Codable, Sendable, Equatable {
        public let id: String
        /// A folder under the trial home's `work/`, named after an invented project.
        public let folder: String
        public let title: String
        public let model: String
        /// `claude` or `codex`: which agent's hooks and files the trial imitates.
        public let agent: String

        public init(id: String, folder: String, title: String, model: String, agent: String = "claude") {
            self.id = id
            self.folder = folder
            self.title = title
            self.model = model
            self.agent = agent
        }

        public var isCodex: Bool { agent == "codex" }
    }

    public struct Beat: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, Equatable {
            case start, prompt, answer, permission, failure
            /// The turn ended with a shell still running: blue, not green. A
            /// monitor would not do: it only listens, and the panel rightly does
            /// not count it as work.
            case background
        }
        /// Seconds from the start of the script.
        public let at: Double
        public let session: String
        public let kind: Kind
        /// The answer, the tool asking for permission, or the failure's reason.
        public let text: String?

        public init(at: Double, session: String, kind: Kind, text: String?) {
            self.at = at
            self.session = session
            self.kind = kind
            self.text = text
        }
    }

    public let sessions: [Session]
    public let beats: [Beat]
    /// The account the allowance strip shows.
    public let account: String
    public let allowanceUsed: Double
    public let allowanceResetMinutes: Int
    /// What LampMaster suggests at the end of the tour.
    public let suggestion: LampMasterAdvice.Suggestion

    public init(
        sessions: [Session], beats: [Beat], account: String, allowanceUsed: Double,
        allowanceResetMinutes: Int, suggestion: LampMasterAdvice.Suggestion
    ) {
        self.sessions = sessions
        self.beats = beats
        self.account = account
        self.allowanceUsed = allowanceUsed
        self.allowanceResetMinutes = allowanceResetMinutes
        self.suggestion = suggestion
    }

    /// The hook payload a beat stands for, as the installed hook would post it.
    ///
    /// - Parameters:
    ///   - work: the trial home's `work/` folder.
    ///   - rollouts: where the trial keeps Codex's rollouts; a Codex session's
    ///     start names its file, as Codex's own hook does.
    public func payload(for beat: Beat, work: String, rollouts: String? = nil) -> [String: Any] {
        let session = sessions.first { $0.id == beat.session }
        var payload: [String: Any] = [
            "session_id": beat.session,
            "cwd": work + "/" + (session?.folder ?? "unknown"),
        ]
        switch beat.kind {
        case .start:
            payload["hook_event_name"] = "SessionStart"
            if session?.isCodex == true, let rollouts {
                payload["transcript_path"] = rollouts + "/rollout-" + beat.session + ".jsonl"
            }
        case .prompt:
            payload["hook_event_name"] = "UserPromptSubmit"
        case .answer:
            payload["hook_event_name"] = "Stop"
            payload["last_assistant_message"] = beat.text ?? ""
        case .permission:
            payload["hook_event_name"] = "Notification"
            payload["notification_type"] = "permission_prompt"
            payload["message"] = "Claude needs your permission to use " + (beat.text ?? "a tool")
        case .failure:
            payload["hook_event_name"] = "StopFailure"
            payload["reason"] = beat.text ?? "unknown"
        case .background:
            payload["hook_event_name"] = "Stop"
            payload["background_tasks"] = [["type": "shell", "status": "running"]]
        }
        return payload
    }

    /// The allowance strip's line in the trial: the script's account, its
    /// session limit, and when it comes back.
    public func allowanceReport(now: Date) -> AllowanceReport {
        AllowanceReport(
            account: ClaudeAccount(email: account, uuid: nil), machine: "mac",
            limits: AccountLimits(limits: [.init(
                span: .session, percent: Int((allowanceUsed * 100).rounded()),
                resetsAt: now.addingTimeInterval(Double(allowanceResetMinutes) * 60)
            )], readAt: now)
        )
    }

    /// The script as JSON, for the site's demo and the screenshots.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension DemoScript {

    /// The tour's script, and the README's picture: six invented projects, one
    /// in each of the panel's six states, the last one a Codex session.
    public static let standard = DemoScript(
        sessions: [
            .init(id: "demo-docs-0001", folder: "docs-site", title: "Docs site build", model: "claude-sonnet-5-5"),
            .init(id: "demo-api-00002", folder: "api", title: "Retry policy", model: "claude-opus-5-5"),
            .init(id: "demo-events-03", folder: "events", title: "Event calendar", model: "claude-opus-5-5"),
            .init(id: "demo-mobile-04", folder: "mobile-client", title: "Booking screen", model: "claude-haiku-4-5"),
            .init(id: "demo-search-05", folder: "search-index", title: "Reindex the catalogue", model: "claude-sonnet-5-5"),
            .init(id: "demo-billing-6", folder: "billing-worker", title: "Invoice retries", model: "gpt-5.6-sol",
                  agent: "codex"),
        ],
        beats: [
            .init(at: 0, session: "demo-docs-0001", kind: .start, text: nil),
            .init(at: 0, session: "demo-api-00002", kind: .start, text: nil),
            .init(at: 0, session: "demo-events-03", kind: .start, text: nil),
            .init(at: 0, session: "demo-mobile-04", kind: .start, text: nil),
            .init(at: 0, session: "demo-search-05", kind: .start, text: nil),
            .init(at: 0, session: "demo-billing-6", kind: .start, text: nil),
            .init(at: 2, session: "demo-search-05", kind: .prompt, text: nil),
            .init(at: 9, session: "demo-search-05", kind: .background, text: nil),
            .init(at: 1, session: "demo-docs-0001", kind: .prompt, text: nil),
            .init(at: 1, session: "demo-events-03", kind: .prompt, text: nil),
            .init(at: 6, session: "demo-docs-0001", kind: .answer, text: "The docs build is ready: 42 pages, no broken links."),
            .init(at: 8, session: "demo-api-00002", kind: .prompt, text: nil),
            .init(at: 11, session: "demo-api-00002", kind: .permission, text: "Bash: npm publish"),
            .init(at: 14, session: "demo-mobile-04", kind: .prompt, text: nil),
            .init(at: 20, session: "demo-mobile-04", kind: .failure, text: "rate_limit"),
        ],
        account: "design@example.com",
        allowanceUsed: 0.62,
        allowanceResetMinutes: 95,
        suggestion: .init(
            kind: .cross, sessions: ["demo-eve", "demo-api"],
            text: "The events calendar calls /api/v2/slots, which the api session renamed to /api/v2/availability.",
            evidence: "api said \"Renamed /api/v2/slots to /api/v2/availability\".",
            action: .init(kind: .ask, target: "demo-eve", question: "The slots endpoint is now /api/v2/availability: update the calendar?"),
            confidence: 0.8, key: "demo slots renamed"
        )
    )
}

/// The answers the trial plays where a real panel would wait on a mod or a
/// model (D120): no mod holds the demo's permission, no fork answers for an
/// invented session, and LampMaster must never run a model in a trial.
extension DemoScript {

    /// The permission the script's `.permission` beat stands for, as the
    /// companion mod would put it to the panel.
    public func heldPermission(now: Date) -> PermissionGate.Request? {
        guard let beat = beats.first(where: { $0.kind == .permission }), let text = beat.text else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let tool = parts.first ?? "Bash", detail = parts.count > 1 ? parts[1] : ""
        var request = PermissionGate.Request(sessionId: beat.session, callId: "toolu_trial_permission", tool: tool,
                                             line: detail.isEmpty ? tool : "\(tool): \(detail)", receivedAt: now)
        request.impact = PermissionImpact.of(tool: tool, line: detail)
        return request
    }

    /// What a session answers a side question with, in the trial.
    public func sideAnswer(for session: String) -> String {
        session == sessions[2].id ? Self.eventsAnswer
            : "In the trial only events answers a side question. Your own sessions answer from their conversation."
    }

    /// What LampMaster answers in the trial, whatever was asked.
    public var lampMasterAnswer: String { Self.lampMasterReply }

    static let eventsAnswer = "The calendar still calls /api/v2/slots in loadAvailability(). It has not been "
        + "changed since the api session renamed the endpoint."
    static let lampMasterReply = "The api session renamed /api/v2/slots to /api/v2/availability an hour ago. "
        + "The events calendar still calls the old path: ask events to update it.\n\n(In the trial LampMaster's answers "
        + "are written in advance; with your sessions it reads them.)"
}

/// Whether a script is fit to show: nothing in it may belong to anybody.
///
/// The same rule as the repository's gate for personal data, applied to the
/// one file that is shown on screens, in screenshots and on the site.
public enum DemoScriptCheck {

    public static let inventedProjects: Set<String> = [
        "docs-site", "api", "events", "mobile-client", "checkout-api", "billing-worker",
        "search-index", "legacy-import",
    ]

    public static func problems(_ script: DemoScript) -> [String] {
        var problems: [String] = []
        let domain = script.account.split(separator: "@").last.map(String.init) ?? ""
        if !["example.com", "example.net"].contains(domain) {
            problems.append("account \(script.account) is not on example.com or example.net")
        }
        for session in script.sessions where !inventedProjects.contains(session.folder) {
            problems.append("project \(session.folder) is not one of the invented ones")
        }
        let ids = Set(script.sessions.map(\.id))
        for beat in script.beats where !ids.contains(beat.session) {
            problems.append("a beat at \(beat.at) s names session \(beat.session), which the script does not have")
        }
        let text = script.json() + script.sideAnswer(for: script.sessions[2].id) + script.lampMasterAnswer
        for marker in ["/Users/", "/home/", "@gmail", "@icloud", "100.64.", "100.1"] where text.contains(marker) {
            problems.append("the script contains \(marker)")
        }
        return problems
    }
}
