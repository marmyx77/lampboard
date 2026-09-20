import Foundation

/// Adds and removes the lampboard hooks inside `~/.claude/settings.json`
/// without touching the rest of the user's configuration.
///
/// It works on dictionaries, not on files: the I/O lives in the app shell, so
/// this logic — which modifies an important user file — stays verifiable.
public enum HookConfigMerger {

    /// Events registered by default.
    ///
    /// These are the edges of the turn plus the subagent ones: the whole traffic
    /// light state is derived from them, at a cost of a handful of `curl` calls
    /// per turn rather than one per tool call.
    ///
    /// The two subagent events cost in proportion to the **number of agents**, not
    /// to tool calls: a thirty-three agent workflow is sixty-six requests over
    /// three quarters of an hour, against the thousands `PreToolUse` would produce.
    /// That is the price of not showing green for a session still working in the
    /// background.
    public static let defaultEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionEnd",
        "SubagentStart",
        "SubagentStop",
        // The only in-turn heartbeat, and it is here for one specific reason: it
        // is the sole registered event that can prove a permission prompt was
        // answered. Without it an amber row keeps flashing at somebody who has
        // already replied, until the turn ends — measured at thirty-three minutes.
        //
        // It does cost one spawn per tool call. Measured on the heaviest real
        // session available: 578 tool calls over thirteen hours, about 44 an hour,
        // each a `curl --max-time 2` that always exits 0.
        //
        // `PreToolUse` stays out. It would double that cost and cannot do the same
        // job: it carries `permissionDecision` in its own output, so it runs
        // *before* the prompt, and one arriving after proves nothing.
        "PostToolUse",
        // Its twin, and not an optional extra. Claude Code emits one or the other:
        // a permitted tool that fails produces only this one, and without it the
        // amber survives the very answer that should have cleared it. Measured on
        // 20 September 2026.
        "PostToolUseFailure",
    ]

    /// Extra event for anyone who wants yellow to move on every tool call too.
    /// It costs one process spawn per call and cannot release a pending question.
    public static let toolEvents = ["PreToolUse"]

    /// The two events that keep running a script even when the rest post natively.
    ///
    /// Both exceptions were measured on 20 September 2026 against Claude Code
    /// 2.1.268 and 2.1.275, and neither is a preference.
    ///
    /// `SessionStart` **cannot** be an `http` hook: registered twice on the same
    /// run, once as `http` and once as `command` pointing at two paths of the same
    /// listener, only the command form ever arrived.
    ///
    /// `SessionEnd` can be, and must not be. It is the **only** event that reports
    /// a failed hook to the person at the keyboard: with the panel not running,
    /// every session ended with `SessionEnd hook failed: connect ECONNREFUSED` on
    /// their screen. `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop`
    /// failed in the same runs and said nothing. Keeping this one on the script —
    /// which pipes the answer to `/dev/null` and exits 0 whatever happens — is what
    /// buys back the silence. Verified on the far side of the tunnel too, where the
    /// panel is off far more often than it is here.
    ///
    /// `Stop` is the third, and it is here for a different reason: it is the only
    /// per-turn event that can **carry the session's git identity**. That identity
    /// is resolved by the script, in the session's own directory, because this app
    /// must never read under somebody's working folder — and a native `http` hook
    /// sends only the headers written into `settings.json`, which cannot contain a
    /// branch nobody has looked up yet.
    ///
    /// Found on the machine this was built on, after the rest of it was working:
    /// with `Stop` posting natively, the identity only ever rode `SessionStart` —
    /// which a brand new session has thrown away (D44) — and `SessionEnd`, which
    /// removes the row it would have decorated. Every row stayed blank and nothing
    /// failed anywhere.
    ///
    /// The cost is one process **per turn**, not per tool call. The measurement
    /// that justified the migration was about `PostToolUse` at 578 invocations in
    /// thirteen hours; `Stop` fires a handful of times an hour and is where the
    /// session is idle by definition.
    public static let commandOnlyEvents: Set<String> = ["SessionStart", "SessionEnd", "Stop"]

    /// Where a native `http` hook posts, and what it carries.
    ///
    /// The headers are the same ones the script sends, because the receiver cannot
    /// tell the two apart and must not have to.
    public struct Endpoint: Sendable, Equatable {
        public let url: String
        public let headers: [String: String]
        /// Variables Claude Code may interpolate into the headers. Anything left
        /// out of this list resolves to an empty string rather than being read.
        public let allowedEnvVars: [String]

        public init(url: String, headers: [String: String], allowedEnvVars: [String]) {
            self.url = url
            self.headers = headers
            self.allowedEnvVars = allowedEnvVars
        }
    }

    /// The endpoint for a given listener, mirroring what `HookScriptBuilder` puts
    /// in the script for the same harness.
    ///
    /// - Parameters:
    ///   - port: the app's port locally; the per-user loopback port the tunnel
    ///     binds on a remote node.
    ///   - token: authorizes the post. Absent is still accepted by the server for
    ///     one more release — see `SignalServer.handleSignal` — so a machine whose
    ///     token could not be read installs a working hook rather than none.
    ///   - host: names the far machine, so a signal arriving through the tunnel is
    ///     told apart from a local one.
    public static func endpoint(
        port: UInt16,
        token: String?,
        harness: Harness = .claudeCode,
        host: String? = nil
    ) -> Endpoint {
        var headers = [AppConfig.harnessHeader: harness.rawValue]
        if let token { headers[AccessToken.headerName] = token }
        if let host { headers[AppConfig.remoteHostHeader] = host }

        // Only Claude Code has this variable, and only it is asked for. Inventing
        // one for Codex would put a lie in a field the workspace resolver trusts.
        var allowed: [String] = []
        if harness == .claudeCode {
            headers[AppConfig.entrypointHeader] = "$CLAUDE_CODE_ENTRYPOINT"
            allowed = ["CLAUDE_CODE_ENTRYPOINT"]
        }

        return Endpoint(
            url: HookScriptBuilder.target(port: port),
            headers: headers,
            allowedEnvVars: allowed
        )
    }

    /// `true` when a URL found in somebody's settings is one of ours.
    ///
    /// Recognition is **structural** — loopback host, our signal path — and not a
    /// marker written into the user's file. A path recorded at install time would
    /// stop matching the moment the port changed, and every stale registration
    /// would survive an uninstall that believed it had cleaned up.
    ///
    /// The cost of this shape is that it would also claim an `http` hook somebody
    /// else pointed at `127.0.0.1/signal`. That is a collision worth accepting:
    /// the alternative leaves orphans, which is the failure that actually happened
    /// here once, under the project's previous name.
    public static func isOurEndpoint(_ url: String) -> Bool {
        guard let parsed = URLComponents(string: url), parsed.scheme == "http" else { return false }
        guard let host = parsed.host, host == AppConfig.listenHost || host == "localhost" else {
            return false
        }
        return parsed.path == AppConfig.signalPath
    }

    /// `true` when one of our **native** registrations does not carry `token`.
    ///
    /// This is the question behind requiring a token on `POST /signal`. Hooks
    /// written by an earlier version carry none, and they sit in somebody's
    /// `settings.json` until a person happens to reinstall them — so "require it a
    /// release later" is not a plan, it is a hope about other people's habits.
    ///
    /// Asked at launch it becomes a fact the app can act on: it knows the token,
    /// it knows which entries are its own, and rewriting them costs one file write
    /// nobody sees. What it must never do is touch an entry that is not ours,
    /// which is why this reads through the same structural recogniser the
    /// uninstaller uses rather than guessing at names.
    ///
    /// Only the `http` form is judged. A command hook carries the token inside the
    /// script, whose text is not visible from here; the caller checks that
    /// separately and rewrites both together.
    public static func lacksToken(
        in settings: [String: Any], scriptPath: String, token: String
    ) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        let doomed: Set<String> = [scriptPath]
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                    guard isOurs(entry, doomed: doomed),
                          entry["type"] as? String == "http" else { continue }
                    let headers = entry["headers"] as? [String: Any]
                    if headers?[AccessToken.headerName] as? String != token { return true }
                }
            }
        }
        return false
    }

    /// The ports our **native** registrations post to. Empty when everything is
    /// on the script, as it is for Codex.
    ///
    /// This is how an instance tells whether an installation is addressed to it.
    /// The launch repair used to skip that question and reinstall at its own port,
    /// and the first thing that did was turn a whole installation towards a second
    /// instance started on another port for a test — which then exited, leaving
    /// every hook posting into the void. An instance may bring hooks up to date;
    /// it may not take them over.
    public static func nativePorts(in settings: [String: Any]) -> Set<UInt16> {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var ports: Set<UInt16> = []
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                    guard let url = entry["url"] as? String, isOurEndpoint(url),
                          let port = URLComponents(string: url)?.port,
                          let narrowed = UInt16(exactly: port) else { continue }
                    ports.insert(narrowed)
                }
            }
        }
        return ports
    }

    /// Hook timeout, in seconds. Twice curl's `--max-time`.
    static let hookTimeout = 3

    // MARK: - Installation

    /// Returns a copy of `settings` with the lampboard hooks registered.
    /// Hooks already present for the same events are preserved.
    ///
    /// - Parameter rewakeScriptPath: when given, a **second** `Stop` hook is
    ///   registered for the chat window's message delivery. It is separate from
    ///   the traffic light hook on purpose: that one must return in milliseconds,
    ///   this one waits for minutes, and putting both behaviors in one script
    ///   would mean the traffic light inherits the waiting.
    /// - Parameter registerMessageDelivery: whether the listener should end up
    ///   registered. It is **always** removed first regardless, which is what makes
    ///   turning the feature off actually turn it off: passing `nil` for the path
    ///   instead left the previous registration in place, and the switch reported
    ///   success while the hook kept running.
    /// - Parameter endpoint: when given, every event outside `commandOnlyEvents`
    ///   is registered as a native `http` hook instead of a script. `nil` keeps
    ///   the whole set on the script, which is what Codex needs — it has a hook
    ///   system of its own and no `http` type in it.
    public static func install(
        into settings: [String: Any],
        scriptPath: String,
        rewakeScriptPath: String? = nil,
        registerMessageDelivery: Bool = true,
        events: [String] = defaultEvents,
        endpoint: Endpoint? = nil
    ) -> [String: Any] {
        // Clean up any previous installation first, so that changing the event
        // list — or switching message delivery off — doesn't leave orphaned
        // registrations behind.
        var result = uninstall(
            from: settings, scriptPaths: [scriptPath, rewakeScriptPath].compactMap { $0 }
        )
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]

        for event in events {
            let existing = (hooks[event] as? [[String: Any]]) ?? []
            let group: [String: Any]
            if let endpoint, !commandOnlyEvents.contains(event) {
                group = httpGroup(endpoint: endpoint)
            } else {
                group = matcherGroup(scriptPath: scriptPath)
            }
            hooks[event] = existing + [group]
        }

        if let rewakeScriptPath, registerMessageDelivery, events.contains("Stop") {
            let existing = (hooks["Stop"] as? [[String: Any]]) ?? []
            hooks["Stop"] = existing + [rewakeGroup(scriptPath: rewakeScriptPath)]
        }

        result["hooks"] = hooks
        return result
    }

    /// Returns a copy of `settings` with no hook pointing at `scriptPath`.
    public static func uninstall(from settings: [String: Any], scriptPath: String) -> [String: Any] {
        uninstall(from: settings, scriptPaths: [scriptPath])
    }

    /// Returns a copy of `settings` with no hook pointing at any of `scriptPaths`.
    public static func uninstall(
        from settings: [String: Any], scriptPaths: [String]
    ) -> [String: Any] {
        var result = settings
        guard let hooks = result["hooks"] as? [String: Any] else { return result }

        let doomed = Set(scriptPaths)
        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                cleaned[event] = value
                continue
            }
            let survivors = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let kept = entries.filter { entry in !isOurs(entry, doomed: doomed) }
                if kept.isEmpty { return nil }
                var updated = group
                updated["hooks"] = kept
                return updated
            }
            if !survivors.isEmpty {
                cleaned[event] = survivors
            }
        }

        if cleaned.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = cleaned
        }
        return result
    }

    /// `true` when at least one hook already points at `scriptPath`.
    public static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
        installedEvents(in: settings, scriptPath: scriptPath).isEmpty == false
    }

    /// Events carrying one of our registrations, in alphabetical order.
    ///
    /// An event counts whether it holds the script or the `http` hook. Reading only
    /// the script would report two events out of nine once the rest post natively,
    /// and every caller asking "is this installed?" would answer almost no.
    public static func installedEvents(in settings: [String: Any], scriptPath: String) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }

        let doomed: Set<String> = [scriptPath]
        let events = hooks.compactMap { event, value -> String? in
            guard let groups = value as? [[String: Any]] else { return nil }
            let found = groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { isOurs($0, doomed: doomed) }
            }
            return found ? event : nil
        }
        return events.sorted()
    }

    // MARK: - Helpers

    /// `true` when this single hook entry belongs to us — either a command running
    /// one of `doomed`, or an `http` hook posting at our endpoint.
    private static func isOurs(_ entry: [String: Any], doomed: Set<String>) -> Bool {
        if let command = entry["command"] as? String { return doomed.contains(command) }
        if let url = entry["url"] as? String { return isOurEndpoint(url) }
        return false
    }

    /// One group holding the native `http` hook for a single event.
    ///
    /// `allowedEnvVars` is written only when something needs it: an empty array in
    /// somebody's `settings.json` is a key they have to look up to discover it says
    /// nothing.
    private static func httpGroup(endpoint: Endpoint) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "http",
            "url": endpoint.url,
            "timeout": hookTimeout,
            "headers": endpoint.headers,
        ]
        if !endpoint.allowedEnvVars.isEmpty {
            hook["allowedEnvVars"] = endpoint.allowedEnvVars
        }
        return ["hooks": [hook]]
    }

    private static func matcherGroup(scriptPath: String) -> [String: Any] {
        [
            "hooks": [
                [
                    "type": "command",
                    "command": scriptPath,
                    "timeout": hookTimeout,
                ] as [String: Any]
            ]
        ]
    }

    /// The message-delivery hook.
    ///
    /// Deliberately carries **no `timeout`**. `asyncRewake` puts the hook on a
    /// detached path that never registers one, and adding the key would be a
    /// statement about a mechanism we do not control — the sort of thing that
    /// looks harmless until a release starts honoring it and every listener is
    /// killed three seconds in.
    private static func rewakeGroup(scriptPath: String) -> [String: Any] {
        [
            "hooks": [
                [
                    "type": "command",
                    "command": scriptPath,
                    "asyncRewake": true,
                    "rewakeMessage": Mailbox.rewakePreamble,
                    "rewakeSummary": Mailbox.rewakeSummary,
                ] as [String: Any]
            ]
        ]
    }
}
