import LampBoardCore
import Foundation

/// What another machine reported about itself.
struct RemoteInspection {
    let home: String
    /// The user the hooks run as there; the tunnel's port is derived from it.
    let uid: Int
    /// Claude Code's settings there; `nil` when the file exists and cannot be parsed.
    let settings: [String: Any]?
    /// sha256 of the settings bytes as read; `nil` when the file did not exist.
    /// Sent back with the write, so nothing is written over a file that changed.
    let settingsSha256: String?
    let pythonVersion: String
    let hasCurl: Bool
    /// Why `~/.lampboard` there cannot be trusted — a symlink, another user's —
    /// or `nil` when it is the user's own directory (or absent).
    let directoryProblem: String?
    let error: String?

    var scriptPath: String { home + "/" + AppConfig.remoteHookScriptRelativePath }

    /// The loopback port the tunnel binds there for this user.
    var port: UInt16 { AppConfig.remotePort(forUID: uid) }

    /// `true` when the lampboard hook is registered there.
    var hooksInstalled: Bool {
        guard let settings else { return false }
        return HookConfigMerger.isInstalled(in: settings, scriptPath: scriptPath)
    }
}

/// Installs and removes the lampboard hooks on another machine.
///
/// The same merge as the local installer — `HookConfigMerger`, verified by the
/// same tests — applied to a file read from the node and written back to it. The
/// hook script it writes there posts through the Unix socket in that user's home
/// which is the far end of the tunnel this app keeps open (`RemoteTunnel`), and
/// names the host in a header so the signal is attributed when it arrives.
///
/// Two round trips, both blocking: inspect, then apply — and the second refuses
/// to write if the settings file is no longer the one that was read (sha256):
/// Claude Code over there writes that file too. Message delivery (the second
/// `Stop` hook) is not installed remotely — the mailbox is local, and that is the
/// boundary that keeps "any process on your machine can start a turn" from
/// extending to every process on the node.
enum RemoteHookInstaller {

    static func inspect(_ host: String) -> Result<RemoteInspection, RemoteCommandError> {
        RemoteCommand.runPythonForObject(on: host, script: RemoteInstallScripts.inspect).flatMap { object in
            // The home becomes the `command` path Claude Code runs through a shell
            // over there. A fixed, checked shape — what the local installer gets
            // for free from `AppConfig.hookScriptURL`.
            guard let home = object["home"] as? String, isPlausibleHome(home) else {
                return .failure(.badAnswer("the home directory there has a shape this app will not put in a command"))
            }
            guard let uid = (object["uid"] as? NSNumber)?.intValue else {
                return .failure(.badAnswer("the machine did not say who it is running as"))
            }
            return .success(RemoteInspection(
                home: home,
                uid: uid,
                settings: object["settings"] as? [String: Any],
                settingsSha256: object["settingsSha256"] as? String,
                pythonVersion: (object["python"] as? String) ?? "?",
                hasCurl: (object["curl"] as? Bool) ?? false,
                directoryProblem: object["directoryProblem"] as? String,
                error: object["error"] as? String
            ))
        }
    }

    /// An absolute path made of letters, digits, `.`, `_`, `-` and `/`.
    static func isPlausibleHome(_ home: String) -> Bool {
        home.hasPrefix("/") && home.count < 256 && !home.contains("//") && home.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "/")
        }
    }

    /// Registers the hooks there. Returns a one-line description of what was done.
    static func install(on host: String) -> Result<String, RemoteCommandError> {
        inspect(host).flatMap { inspection in
            guard let settings = inspection.settings else {
                return .failure(.remoteFailure(
                    "settings.json there cannot be parsed (\(inspection.error ?? "unknown error")); nothing was changed"
                ))
            }
            guard inspection.hasCurl else {
                return .failure(.remoteFailure("curl is missing there, and the hook script needs it"))
            }
            if let problem = inspection.directoryProblem {
                return .failure(.remoteFailure("~/.lampboard there \(problem); nothing was changed"))
            }
            // The far side posts natively too. It is not the secondary case it was
            // taken for: most of the work this panel watches happens over the
            // tunnel, so the node is where the saved process spawns are actually
            // worth something. Proved end-to-end on 20 September 2026 — a session
            // there, through the reverse tunnel, to the listener here — including
            // with the tunnel down, where the hybrid shape stays silent.
            //
            // The token is the **local** one: what authorizes the post is the
            // server at this end, which is where the tunnel lands.
            let endpoint = HookConfigMerger.endpoint(
                port: inspection.port,
                token: TokenStore().read(),
                harness: .claudeCode,
                host: host
            )
            let merged = HookConfigMerger.install(
                into: settings,
                scriptPath: inspection.scriptPath,
                rewakeScriptPath: nil,
                registerMessageDelivery: false,
                endpoint: endpoint
            )
            return apply(on: host, payload: [
                "scriptRelativePath": AppConfig.remoteHookScriptRelativePath,
                "settingsRelativePath": AppConfig.remoteClaudeSettingsRelativePath,
                "settings": merged,
                "expectedSha256": inspection.settingsSha256 ?? NSNull(),
                "hookScript": HookScriptBuilder.script(
                    port: inspection.port, host: host, token: TokenStore().read()
                ),
            ]).map { result in
                let backup = (result["backup"] as? String).map { " (backup: \($0))" } ?? ""
                return "hooks installed on \(host), posting to 127.0.0.1:\(inspection.port) there\(backup)"
            }
        }
    }

    /// Removes the hooks and the script there.
    static func uninstall(on host: String) -> Result<String, RemoteCommandError> {
        inspect(host).flatMap { inspection in
            guard let settings = inspection.settings else {
                return .failure(.remoteFailure(
                    "settings.json there cannot be parsed (\(inspection.error ?? "unknown error")); nothing was changed"
                ))
            }
            let cleaned = HookConfigMerger.uninstall(from: settings, scriptPath: inspection.scriptPath)
            return apply(on: host, payload: [
                "scriptRelativePath": AppConfig.remoteHookScriptRelativePath,
                "settingsRelativePath": AppConfig.remoteClaudeSettingsRelativePath,
                "settings": cleaned,
                "expectedSha256": inspection.settingsSha256 ?? NSNull(),
                "removeScript": true,
            ]).map { _ in "hooks removed from \(host)" }
        }
    }

    /// What the node says about the tunnel's far end.
    struct TunnelStatus {
        /// `true` when `127.0.0.1:<port>` there answered with HTTP — this app, then.
        let answers: Bool
        /// Every local address the port is bound on there. Loopback only is the goal.
        let boundAddresses: [String]

        var exposedOn: String? {
            boundAddresses.first { $0 != "127.0.0.1" && $0 != "::1" }
        }

        var sentence: String {
            if let address = exposedOn { return "the forward is bound on \(address) there: EXPOSED, the tunnel refuses to carry it" }
            if answers { return "the tunnel answers from there (loopback only)" }
            if boundAddresses.isEmpty { return "nothing is bound on the port there yet: is the panel running?" }
            return "the port is bound there but does not answer as this app"
        }
    }

    /// Asks the node where the tunnel's port is bound and whether it answers —
    /// *from* the node, because the client's `-R 127.0.0.1` is a request and this
    /// is the answer.
    static func tunnelStatus(on host: String, port: UInt16) -> Result<TunnelStatus, RemoteCommandError> {
        RemoteCommand.runPythonForObject(on: host, script: RemoteInstallScripts.checkTunnel(port: port)).map { object in
            TunnelStatus(
                answers: object["status"] is NSNumber,
                boundAddresses: (object["bound"] as? [String]) ?? []
            )
        }
    }

    private static func apply(
        on host: String, payload: [String: Any]
    ) -> Result<[String: Any], RemoteCommandError> {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .failure(.badAnswer("the payload could not be encoded"))
        }
        return RemoteCommand.runPythonForObject(
            on: host,
            script: RemoteInstallScripts.apply(payloadBase64: data.base64EncodedString()),
            timeout: AppConfig.remoteProbeTimeout * 2
        ).flatMap { result in
            guard (result["ok"] as? Bool) == true else {
                let reason = (result["reason"] as? String) ?? "the machine did not confirm the write"
                return .failure(.remoteFailure(reason))
            }
            return .success(result)
        }
    }
}
