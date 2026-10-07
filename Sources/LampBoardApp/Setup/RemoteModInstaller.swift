import Foundation
import LampBoardCore

/// The companion mod on another machine (the bridge, B1): put there with the
/// hooks when the mod is on here, brought to this app's version at launch,
/// taken out with the hooks. What it writes there is `RemoteModScripts`'.
enum RemoteModInstaller {

    /// Installs, or reinstalls, the mod there. A one-line account of it.
    static func install(on host: String, inspection: RemoteInspection) -> Result<String, RemoteCommandError> {
        guard ModRegistration.isSupported(by: inspection.claudeVersion) else {
            let version = inspection.claudeVersion.map { "\($0)" } ?? "unknown"
            return .failure(.remoteFailure("Claude Code there is \(version); the helper needs 2.1.287 or later"))
        }
        guard let token = TokenStore().read(), let key = TokenStore(url: AppConfig.checkKeyURL).read() else {
            return .failure(.remoteFailure("this panel has no token or permission key to give the helper there"))
        }
        return run(on: host, RemoteModScripts.payload(token: token, port: inspection.port, checkKey: key))
            .map { "helper \(ModFiles.version) installed on \(host), reporting through the tunnel" }
    }

    /// Takes it out there, and the three files it read.
    static func uninstall(on host: String, inspection: RemoteInspection) -> Result<String, RemoteCommandError> {
        run(on: host, RemoteModScripts.removal(port: inspection.port)).map { "helper removed from \(host)" }
    }

    /// At launch, like the hooks' token: a node whose mod is older than this
    /// app's gets this one; a newer one, put there by a newer panel, stays. A node without it is left alone — the
    /// mod goes there when asked, with `remote install`.
    static func refresh(on host: String, inspection: RemoteInspection) -> Result<String, RemoteCommandError>? {
        guard ModSetup.isInstalled, let there = inspection.modVersion,
              let theirs = ReleaseVersion(there), let ours = ReleaseVersion(ModFiles.version), theirs < ours else { return nil }
        return install(on: host, inspection: inspection).map { _ in "helper there brought from \(there) to \(ModFiles.version)" }
    }

    private static func run(on host: String, _ payload: [String: Any]) -> Result<Void, RemoteCommandError> {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return .failure(.badAnswer("the payload could not be encoded"))
        }
        // `claude plugin` there takes seconds each, two to four times.
        return RemoteCommand.runPythonForObject(
            on: host, script: RemoteModScripts.script(payloadBase64: data.base64EncodedString()), timeout: 60
        ).flatMap { result in
            guard (result["ok"] as? Bool) == true else {
                return .failure(.remoteFailure((result["reason"] as? String) ?? "the machine did not confirm it"))
            }
            return .success(())
        }
    }
}

extension RemoteHookInstaller {

    /// The hooks, and the mod with them when it is on here (B1): a failure of
    /// the mod is said after the hooks' line, and leaves the hooks in place.
    static func installWithMod(on host: String) -> Result<String, RemoteCommandError> {
        install(on: host).map { hooks in
            guard ModSetup.isInstalled else { return hooks }
            switch inspect(host).flatMap({ RemoteModInstaller.install(on: host, inspection: $0) }) {
            case .success(let mod): return hooks + "; " + mod
            case .failure(let error): return hooks + "; helper not installed there: " + error.short
            }
        }
    }

    /// The mod first, while the inspection can still find it, then the hooks.
    static func uninstallWithMod(on host: String) -> Result<String, RemoteCommandError> {
        let mod = inspect(host).flatMap { inspection -> Result<String, RemoteCommandError> in
            guard inspection.modVersion != nil else { return .success("") }
            return RemoteModInstaller.uninstall(on: host, inspection: inspection)
        }
        return uninstall(on: host).map { hooks in
            switch mod {
            case .success(let text): return text.isEmpty ? hooks : hooks + "; " + text
            case .failure(let error): return hooks + "; helper there not removed: " + error.short
            }
        }
    }
}
