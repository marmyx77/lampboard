import LampBoardCore
import Foundation

/// Which Claude Code is installed on this Mac, read rather than assumed.
///
/// Two places are looked at, in order. The native installer keeps every version
/// under `~/.local/share/claude/versions/<version>` and points
/// `~/.local/bin/claude` at the current one, so the link's target *is* the
/// version and costs no process. Failing that, `claude --version` is run from
/// the places a binary usually lives — a GUI application's `PATH` is four system
/// directories, none of which is where anybody installs Claude Code — with a
/// deadline, because a tool that hangs must not hang the installer.
///
/// `nil` means "could not read", and `NativeHookSupport` reads that as current.
enum ClaudeCodeInstallation {

    static func installedVersion() -> ReleaseVersion? {
        fromNativeInstaller() ?? fromRunning()
    }

    /// `true` when the hooks may post natively here.
    static func supportsNativeHooks() -> Bool {
        NativeHookSupport.isAvailable(in: installedVersion())
    }

    /// The sentence for a degraded installation, or `nil`.
    static func nativeHooksNote() -> String? {
        NativeHookSupport.note(for: installedVersion())
    }

    // MARK: - Internal

    private static var link: URL {
        AppConfig.homeDirectory.appendingPathComponent(".local/bin/claude")
    }

    private static func fromNativeInstaller() -> ReleaseVersion? {
        guard (try? link.checkResourceIsReachable()) == true else { return nil }
        let target = link.resolvingSymlinksInPath()
        guard target != link else { return nil }
        // `…/versions/2.1.278` names the binary after its version; should a
        // layout ever put the binary inside the directory, the parent does.
        return ReleaseVersion(target.lastPathComponent)
            ?? ReleaseVersion(target.deletingLastPathComponent().lastPathComponent)
    }

    private static func fromRunning() -> ReleaseVersion? {
        let candidates = [link.path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/claude" }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            guard let result = try? Command.run(
                path, ["--version"], deadline: AppConfig.focusProbeTimeout
            ), result.status == 0 else { continue }
            if let version = NativeHookSupport.version(fromOutput: result.output) { return version }
        }
        return nil
    }
}
