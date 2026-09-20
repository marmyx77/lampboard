import Foundation

/// Decoding errors for a hook payload.
public enum HookPayloadError: Error, Equatable, CustomStringConvertible {
    case bodyTooLarge(Int)
    case invalidJSON
    case notAnObject
    case missingField(String)
    case emptyField(String)
    case relativePath(field: String, value: String)
    /// The event is syntactically valid but moves no traffic light.
    /// Not a fault: callers treat it as a no-op.
    case ignoredEvent(String)

    public var description: String {
        switch self {
        case .bodyTooLarge(let size):
            return "body of \(size) bytes exceeds the limit of \(AppConfig.maxRequestBodyBytes)"
        case .invalidJSON:
            return "body is not valid JSON"
        case .notAnObject:
            return "top-level JSON is not an object"
        case .missingField(let name):
            return "required field missing: \(name)"
        case .emptyField(let name):
            return "required field empty: \(name)"
        case .relativePath(let field, let value):
            return "field \(field) must be an absolute path, received: \(value)"
        case .ignoredEvent(let name):
            return "irrelevant event: \(name)"
        }
    }

    /// `true` when the error should be logged as an anomaly. `ignoredEvent` is business as usual.
    public var isFailure: Bool {
        if case .ignoredEvent = self { return false }
        return true
    }
}

/// Decodes and validates the JSON Claude Code hands to the hooks.
///
/// This is the only point where external data enters the domain, so it validates
/// strictly: no required field is ever inferred or filled in with a default.
public enum HookPayloadDecoder {
    /// - Parameters:
    ///   - data: request body.
    ///   - entrypoint: value of `CLAUDE_CODE_ENTRYPOINT` read by the hook script
    ///     and carried in a header; it is not present in Claude Code's JSON.
    ///   - host: the `X-LampBoard-Host` header, present when the hook ran on another
    ///     machine. Anything that is not a plausible host name is dropped rather
    ///     than carried: the value ends up in a row label and in an ssh argument.
    ///   - git: repository and branch, resolved by the script in the session's own
    ///     directory and carried in three headers. Only a session start has them.
    public static func decode(
        _ data: Data,
        entrypoint: String? = nil,
        host: String? = nil,
        harness: Harness = .claudeCode,
        git: GitIdentity? = nil
    ) throws -> HookSignal {
        guard data.count <= AppConfig.maxRequestBodyBytes else {
            throw HookPayloadError.bodyTooLarge(data.count)
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw HookPayloadError.invalidJSON
        }

        guard let object = parsed as? [String: Any] else {
            throw HookPayloadError.notAnObject
        }

        let sessionId = try requiredString(object, key: "session_id")
        let eventName = try requiredString(object, key: "hook_event_name")
        let cwd = try requiredString(object, key: "cwd")

        guard cwd.hasPrefix("/") else {
            throw HookPayloadError.relativePath(field: "cwd", value: cwd)
        }

        guard let event = HookEventKind(rawValue: eventName) else {
            throw HookPayloadError.ignoredEvent(eventName)
        }

        let host = host?.trimmed.nilIfEmpty.flatMap { RemoteHostList.isUsable($0) ? $0 : nil }

        return HookSignal(
            sessionId: sessionId,
            event: event,
            cwd: PathNormalizer.normalize(cwd),
            notificationKind: (object["notification_type"] as? String)
                .flatMap(NotificationKind.init(rawValue:)),
            agentId: optionalString(object, key: "agent_id"),
            entrypoint: entrypoint?.trimmed.nilIfEmpty,
            lastAssistantMessage: optionalString(object, key: "last_assistant_message"),
            sessionSource: optionalString(object, key: "source"),
            failureReason: failureReason(in: object, event: event),
            inFlightBackgroundTaskTypes: inFlightBackgroundTaskTypes(in: object),
            // A transcript on another machine is not a file here. Keeping the path
            // would make the chat window open an empty conversation and call it
            // "nothing was said".
            transcriptPath: host == nil
                ? TranscriptPathPolicy.accepted(
                    optionalString(object, key: "transcript_path"),
                    under: harness.transcriptRoot)
                : nil,
            host: host,
            harness: harness,
            git: git,
            // Only from the event that actually carries it. Reading `tool_name`
            // off a `PostToolUse` would attach the tool that just *finished* to a
            // row that is blocked on something else entirely.
            pendingAsk: event == .permissionRequest
                ? PendingAsk.from(
                    toolName: optionalString(object, key: "tool_name"),
                    toolInput: object["tool_input"]
                )
                : nil
        )
    }

    /// Cause of the interruption for `StopFailure`.
    ///
    /// Two field names are tried because the documentation uses both in different
    /// sections. If neither is present the cause stays `unknown`: what must never
    /// happen is for a missing field to make the turn look successful.
    private static func failureReason(
        in object: [String: Any],
        event: HookEventKind
    ) -> StopFailureReason? {
        guard event == .stopFailure else { return nil }
        let raw = optionalString(object, key: "error_type")
            ?? optionalString(object, key: "error")
        return StopFailureReason.from(rawValue: raw)
    }

    /// Statuses that mean the work is over.
    ///
    /// A **deny**-list, and deliberately the opposite choice from `isValidSessionId`
    /// two files away, because the two questions have opposite expensive answers.
    /// There an unknown character had to be refused; here an unknown status has to
    /// count. Guessing "busy" costs a yellow that clears on the next clean turn.
    /// Guessing "finished" costs a green that says the work is done while it runs —
    /// the lie this whole field exists to prevent.
    ///
    /// The vocabulary observed today is `pending, running, completed, failed,
    /// killed, paused`.
    private static let finishedTaskStatuses: Set<String> = ["completed", "failed", "killed"]

    /// Counts the background work still in flight at the end of the turn.
    ///
    /// **Presence in the list is the signal**, not the status word. Claude Code
    /// filters the array before sending it — only `running` or `pending`, and only
    /// if backgrounded — and documents it as holding "in-flight background work…
    /// empty array when nothing is in flight". So the previous reading here had it
    /// backwards twice over: it defended against finished tasks, which never arrive,
    /// and by doing so it dropped `pending` ones, which do. A task registered but
    /// not yet started is work that is about to wake the session, and counting it as
    /// nothing put the row green in front of it.
    ///
    /// The status is still read, for the one case that survives: if that upstream
    /// filter ever loosened, a finished task must not hold the row yellow for ever.
    private static func inFlightBackgroundTaskTypes(in object: [String: Any]) -> [String] {
        guard let tasks = object["background_tasks"] as? [[String: Any]] else { return [] }
        return tasks.filter { task in
            guard let status = (task["status"] as? String)?.trimmed.lowercased() else {
                return true
            }
            return !finishedTaskStatuses.contains(status)
        }.map { ($0["type"] as? String)?.trimmed.nilIfEmpty ?? "?" }
    }

    // MARK: - Helpers

    private static func requiredString(_ object: [String: Any], key: String) throws -> String {
        guard let raw = object[key] else {
            throw HookPayloadError.missingField(key)
        }
        guard let value = raw as? String else {
            throw HookPayloadError.missingField(key)
        }
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else {
            throw HookPayloadError.emptyField(key)
        }
        return trimmed
    }

    private static func optionalString(_ object: [String: Any], key: String) -> String? {
        (object[key] as? String)?.trimmed.nilIfEmpty
    }

    /// An optional field that is only usable as an absolute path.
    ///
    /// A relative one is dropped rather than kept: this value ends up being opened
    /// for reading, and resolving it against whatever the app's working directory
    /// happens to be would read a file nobody asked for.
    private static func absolutePath(_ object: [String: Any], key: String) -> String? {
        guard let value = optionalString(object, key: key), value.hasPrefix("/") else {
            return nil
        }
        return value
    }
}
