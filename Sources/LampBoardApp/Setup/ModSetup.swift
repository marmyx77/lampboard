import LampBoardCore
import Foundation

/// Puts the companion mod into Claude Code, and takes it out.
///
/// The app writes the mod it carries into `~/.lampboard/mod-marketplace`, a
/// folder that stays where it is when the app moves, and hands that folder to
/// Claude Code's own `claude plugin` commands (D66). What is installed is then
/// exactly what this panel reads. Off until somebody turns it on: it runs in
/// every session they open, and that is theirs to agree to.
enum ModSetup {

    enum Outcome: Equatable {
        case done
        case failed(String)
    }

    static var folder: URL {
        AppConfig.supportDirectory.appendingPathComponent("mod-marketplace", isDirectory: true)
    }

    private static var settingsURL: URL {
        AppConfig.claudeDirectory.appendingPathComponent("settings.json")
    }

    private static var recordsURL: URL {
        AppConfig.claudeDirectory.appendingPathComponent("plugins/installed_plugins.json")
    }

    private static var marketplacesURL: URL {
        AppConfig.claudeDirectory.appendingPathComponent("plugins/known_marketplaces.json")
    }

    /// The last failure of an install the user did not watch — the launch
    /// refresh — kept for Settings to show, and cleared by the next success.
    static var problemURL: URL {
        AppConfig.supportDirectory.appendingPathComponent("mod-problem.txt")
    }

    static var isInstalled: Bool {
        ModRegistration.isEnabled(settings: try? Data(contentsOf: settingsURL))
    }

    static var installedVersion: String? {
        ModRegistration.installedVersion(records: try? Data(contentsOf: recordsURL))
    }

    /// Anything of the mod Claude Code still knows: enabled or not, the plugin
    /// recorded, or the marketplace declared.
    static var isPresent: Bool {
        isInstalled || installedVersion != nil
            || ModRegistration.isMarketplaceDeclared(
                settings: try? Data(contentsOf: settingsURL), known: try? Data(contentsOf: marketplacesURL))
    }

    static var lastProblem: String? {
        (try? String(contentsOf: problemURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the mod cannot go in on this Mac, or `nil` when it can.
    static func obstacle() -> String? {
        let version = ClaudeCodeInstallation.installedVersion()
        guard ModRegistration.isSupported(by: version) else {
            return "Claude Code \(version.map { "\($0)" } ?? "") is older than \(ModRegistration.firstRelease), "
                + "the first that can run the helper. The connection keeps the panel working meanwhile."
        }
        return nil
    }

    static func install() -> Outcome {
        exclusively { installUnlocked() }
    }

    static func uninstall() -> Outcome {
        exclusively { uninstallUnlocked() }
    }

    /// At launch: an installed mod older or newer than the one this app
    /// carries is replaced, so the two ends always speak the same version. A
    /// failure is kept for Settings to show: the old mod is already out by then
    /// (its marketplace is the folder being rewritten), and a line in a log
    /// nobody reads would leave somebody without it and without knowing.
    static func refreshIfStale() {
        let outcome: Outcome? = exclusively {
            guard isInstalled, let installed = installedVersion, installed != ModFiles.version else { return nil }
            return installUnlocked()
        }
        if case .failed(let reason)? = outcome {
            Diagnostics.log("mod refresh failed: \(reason)")
            try? "The LampBoard helper could not be updated: \(reason)".write(to: problemURL, atomically: true, encoding: .utf8)
        }
    }

    /// From a clean slate, always: a marketplace left declared by an earlier
    /// version, a half-finished install or a hand, makes `add` refuse; taking it
    /// out of a Claude Code that does not have it only fails, harmlessly. On any
    /// failure what was half put in is taken out again, so the next try starts
    /// clean instead of tripping on the remains of this one.
    private static func installUnlocked() -> Outcome {
        if let obstacle = obstacle() { return .failed(obstacle) }
        if isPresent { _ = uninstallUnlocked() }
        if let failure = writeFiles() { return .failed(failure) }
        for step in ModRegistration.installSteps(folder: folder.path) {
            if case .failed(let reason) = claude(step) {
                _ = uninstallUnlocked()
                return .failed(reason)
            }
        }
        try? FileManager.default.removeItem(at: problemURL)
        return .done
    }

    /// Both steps are tried even when the first fails. Judged by what Claude
    /// Code still knows, not by the exit codes; and the folder goes only once
    /// no marketplace points at it.
    private static func uninstallUnlocked() -> Outcome {
        let outcomes = ModRegistration.uninstallSteps.map(claude)
        guard !isPresent else {
            return outcomes.first { $0 != .done } ?? .failed("Claude Code still lists the LampBoard helper.")
        }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: problemURL)
        return .done
    }

    /// One change at a time, across this app's threads and the command line:
    /// the launch refresh, the Settings switch, Getting started and `lampboard
    /// mod` would otherwise interleave their `claude` runs and undo each other.
    private static func exclusively<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: AppConfig.supportDirectory, withIntermediateDirectories: true)
        let fd = open(AppConfig.supportDirectory.appendingPathComponent("mod.lock").path,
                      O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    /// The carried files, written owner-only into a fresh folder.
    static func writeFiles(into folder: URL = folder) -> String? {
        let fileManager = FileManager.default
        do {
            try? fileManager.removeItem(at: folder)
            for file in ModFiles.all {
                let url = folder.appendingPathComponent(file.path)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard fileManager.createFile(
                    atPath: url.path, contents: Data(file.content.utf8), attributes: [.posixPermissions: 0o600]
                ) else { return "Could not write \(url.path)." }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Under `LAMPBOARD_HOME`, `claude` is told the fake home is its home:
    /// it writes `~/.claude/settings.json` from `HOME`, and a child inheriting
    /// the real one would install into the real Claude Code from inside a test.
    /// `CLAUDE_CONFIG_DIR` is taken away for the same reason: set in the shell
    /// that runs the tests, it would point `claude` back at the real folder.
    static var claudeEnvironment: [String: String?] {
        AppConfig.isUsingHomeOverride ? ["HOME": AppConfig.homeDirectory.path, "CLAUDE_CONFIG_DIR": nil] : [:]
    }

    /// The same `claude` LampMaster runs, found the same way: under
    /// `LAMPBOARD_HOME` only the fake home's.
    private static func claude(_ arguments: [String]) -> Outcome {
        guard let tool = LampMasterRunner.executable() else {
            return .failed("Claude Code's claude command was not found.")
        }
        do {
            let result = try Command.run(tool, arguments, deadline: 60, input: Data(), environment: claudeEnvironment)
            return result.succeeded ? .done : .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let failure as Command.Failure {
            return .failed(failure.explanation)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension ModSetup {

    /// `lampboard mod install | uninstall | status`.
    static func command(_ verb: String) -> Int32 {
        let outcome: Outcome
        switch verb {
        case "install": outcome = install()
        case "uninstall": outcome = uninstall()
        case "status":
            print(isInstalled
                ? "The LampBoard mod is installed (\(installedVersion ?? "version unknown")); this app carries \(ModFiles.version)."
                : "The LampBoard mod is not installed." + (obstacle().map { " " + $0 } ?? ""))
            return 0
        default:
            FileHandle.standardError.write(Data("mod: unknown verb \(verb); use install, uninstall or status\n".utf8))
            return 2
        }
        switch outcome {
        case .done:
            print(verb == "install"
                ? "The LampBoard mod is installed. Sessions started from now on report their context, cost and limits."
                : "The LampBoard mod is removed from Claude Code.")
            return 0
        case .failed(let reason):
            FileHandle.standardError.write(Data("mod: \(reason)\n".utf8))
            return 1
        }
    }
}

extension ModSetup {

    struct Refusal: Error { let reason: String }

    /// Claude Code's reading of the mod this app carries, from a scratch copy:
    /// what would be installed, whether or not it is.
    static func describe() -> Result<ModTrust.Reading, Refusal> {
        guard let tool = LampMasterRunner.executable() else {
            return .failure(Refusal(reason: "Claude Code's claude command was not found."))
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lampboard-mod-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        if let failure = writeFiles(into: scratch) { return .failure(Refusal(reason: failure)) }
        do {
            let result = try Command.run(
                tool, ["plugin", "validate", "--strict", "--json", scratch.appendingPathComponent("mod").path],
                deadline: 60, capturingStandardError: false, input: Data(), environment: claudeEnvironment
            )
            guard let reading = ModTrust.read(validateJSON: Data(result.output.utf8)) else {
                return .failure(Refusal(reason: "Claude Code's answer could not be read: " + String(result.output.prefix(200))))
            }
            return .success(reading)
        } catch let failure as Command.Failure {
            return .failure(Refusal(reason: failure.explanation))
        } catch {
            return .failure(Refusal(reason: error.localizedDescription))
        }
    }
}
