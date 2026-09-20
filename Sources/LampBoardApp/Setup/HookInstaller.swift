import LampBoardCore
import Foundation

/// Hook installation errors.
enum HookInstallError: LocalizedError {
    case unreadableSettings(path: String, reason: String)
    case unwritableSettings(path: String, reason: String)
    case scriptWriteFailed(String)

    /// Names the file it actually touched.
    ///
    /// It used to say `~/.claude/settings.json` whatever had failed, including
    /// when the failing instance was the Codex one writing `~/.codex/hooks.json`.
    /// An error that names the wrong file is worse than one that names none: it
    /// sends somebody to check a file that is perfectly fine, and everything they
    /// find there confirms it.
    var errorDescription: String? {
        switch self {
        case .unreadableSettings(let path, let reason):
            return "Cannot read \(HookInstallError.short(path)): \(reason)"
        case .unwritableSettings(let path, let reason):
            return "Cannot write \(HookInstallError.short(path)): \(reason)"
        case .scriptWriteFailed(let reason):
            return "Cannot write the hook script: \(reason)"
        }
    }

    /// The home written as a tilde, because that is how a person reads a path.
    private static func short(_ path: String) -> String {
        let home = AppConfig.homeDirectory.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Installs and removes the lampboard hooks from the Claude Code configuration.
///
/// It touches a file the user relies on every day, so every write is preceded by
/// a dated backup and happens atomically: an interruption halfway through leaves
/// the previous file intact rather than a truncated JSON.
struct HookInstaller {
    private let settingsURL: URL
    private let scriptURL: URL
    private let rewakeScriptURL: URL
    private let fileManager: FileManager
    private let harness: Harness

    init(
        settingsURL: URL = AppConfig.claudeSettingsURL,
        scriptURL: URL = AppConfig.hookScriptURL,
        rewakeScriptURL: URL = AppConfig.rewakeScriptURL,
        fileManager: FileManager = .default,
        harness: Harness = .claudeCode
    ) {
        self.harness = harness
        self.settingsURL = settingsURL
        self.scriptURL = scriptURL
        self.rewakeScriptURL = rewakeScriptURL
        self.fileManager = fileManager
    }

    /// The installer for Codex, pointed at Codex's own files.
    ///
    /// A second instance rather than a mode, because everything that differs is
    /// already a parameter: where the configuration lives, which script to write,
    /// and which events to ask for.
    static func codex(fileManager: FileManager = .default) -> HookInstaller {
        HookInstaller(
            settingsURL: AppConfig.codexHooksURL,
            scriptURL: AppConfig.codexHookScriptURL,
            // Message delivery is a Claude Code feature: it rides a second `Stop`
            // hook that answers a mailbox, and Codex has no path back into a
            // session for it to answer through. Naming a file that is never
            // written keeps uninstall symmetric without inventing a feature.
            rewakeScriptURL: AppConfig.codexHookScriptURL
                .deletingLastPathComponent()
                .appendingPathComponent("codex-rewake.sh"),
            fileManager: fileManager,
            harness: .codex
        )
    }

    /// What a person must still do by hand after Codex's hooks are written.
    ///
    /// Codex will not run a hook it has not been told to trust, and it says
    /// nothing when it declines: the file is correct, the events never fire, and
    /// there is no error anywhere to explain it. Finding that out cost an hour
    /// here, and printing this sentence is what stops it costing anybody else one.
    static let codexTrustNotice = """
        Codex will not run these hooks until you trust them. Open Codex, run
        /hooks, and approve the entry. Until then Codex reports nothing, and
        says nothing about why.
        """

    var scriptPath: String { scriptURL.path }
    var rewakeScriptPath: String { rewakeScriptURL.path }

    /// The two scripts under the name this project used to have, so an install
    /// can remove them. Derived from the *current* file names rather than
    /// spelled out again: the pair must stay a pair, and a rename of `hook.sh`
    /// that forgot this list would leave an orphan behind with nothing to catch it.
    var legacyScriptPaths: [String] {
        [scriptURL, rewakeScriptURL].map {
            AppConfig.legacySupportDirectory
                .appendingPathComponent($0.lastPathComponent).path
        }
    }

    // MARK: - State

    func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return HookConfigMerger.isInstalled(in: settings, scriptPath: scriptPath)
    }

    func installedEvents() -> [String] {
        guard let settings = try? readSettings() else { return [] }
        return HookConfigMerger.installedEvents(in: settings, scriptPath: scriptPath)
    }

    /// Rewrites our own registrations when they do not carry the current token.
    ///
    /// Called at launch, and it is what turns "require a token in a later release"
    /// from a hope about other people's habits into something this app finishes by
    /// itself. It touches only entries the structural recogniser claims as ours,
    /// and it writes nothing when there is nothing to change.
    ///
    /// Two things can be stale, and both are checked: the header on a native hook,
    /// which `HookConfigMerger.lacksToken` reads out of the settings, and the
    /// script, whose token lives inside its own text — a file this process can
    /// simply read.
    ///
    /// **Only an installation addressed to this instance is touched**, and what it
    /// gets is a repair, not a fresh installation. The first version reinstalled at
    /// its own port with a fresh installation's defaults, and the end-to-end run
    /// showed what that means: a second instance started on another port for one
    /// case found a stale script, rewrote every hook to post to itself, and exited
    /// — leaving the next cases posting into the void. The same code would have
    /// dropped `PreToolUse` and message delivery from anybody who had them. So the
    /// port is read off the hooks, and the shape they had is the shape they keep.
    ///
    /// - Parameter token: the value this launch has settled on. Passed in rather
    ///   than read, because the launch may just have regenerated it and a read
    ///   here would see the burned one.
    /// - Returns: `true` when something was rewritten.
    @discardableResult
    func repairToken(port: UInt16 = AppConfig.listenPort, token: String?) -> Bool {
        guard let token, let settings = try? readSettings() else { return false }
        let events = HookConfigMerger.installedEvents(in: settings, scriptPath: scriptPath)
        guard !events.isEmpty else { return false }

        let scriptText = try? String(contentsOf: scriptURL, encoding: .utf8)
        guard isAddressed(to: port, settings: settings, scriptText: scriptText) else { return false }

        let headerStale = HookConfigMerger.lacksToken(
            in: settings, scriptPath: scriptPath, token: token
        )
        let scriptStale = !(scriptText?.contains(token) ?? false)
        guard headerStale || scriptStale else { return false }

        do {
            try install(
                port: port,
                includeToolEvents: HookConfigMerger.toolEvents.allSatisfy(events.contains),
                includeMessageDelivery: HookConfigMerger.isInstalled(
                    in: settings, scriptPath: rewakeScriptPath
                ),
                token: token
            )
            Diagnostics.log("hooks rewritten to carry the current token (\(harness.rawValue))")
            return true
        } catch {
            // Never fatal. A panel that refused to start because it could not
            // rewrite a header would be trading the whole feature for the last
            // step of a migration.
            Diagnostics.log("could not rewrite the hooks: \(error.localizedDescription)")
            return false
        }
    }

    /// `true` when the installed hooks post to `port` — to this instance, then.
    ///
    /// The native registrations say so in their URL. When there are none — Codex
    /// keeps everything on the script — the script's own target is the record, and
    /// an installation with neither is nobody's to repair.
    private func isAddressed(to port: UInt16, settings: [String: Any], scriptText: String?) -> Bool {
        let native = HookConfigMerger.nativePorts(in: settings)
        if !native.isEmpty { return native == [port] }
        guard let scriptText else { return false }
        return HookScriptBuilder.posts(scriptText, to: port)
    }

    // MARK: - Operations

    /// Writes the hook script and registers it in `settings.json`.
    /// - Returns: the path of the backup created, if `settings.json` already existed.
    @discardableResult
    /// - Parameter includeMessageDelivery: registers the second `Stop` hook that
    ///   carries messages from the chat window into a session. **Off unless the
    ///   user has turned sending on**: while it is off there is no listener and no
    ///   mailbox, so nothing on the machine can start a turn in their name.
    /// - Parameter token: authorizes the posts. Read here rather than asked for,
    ///   the same way `LocalClient` reads it. `nil` — an unreadable file, a home
    ///   that isn't writable — installs a hook without the header instead of no
    ///   hook at all: the server still accepts an absent token, and a panel that
    ///   works beats one that refused to set itself up over a secret it only uses
    ///   to tell its own hooks apart.
    func install(
        port: UInt16 = AppConfig.listenPort,
        includeToolEvents: Bool = false,
        includeMessageDelivery: Bool = false,
        token: String? = TokenStore().read()
    ) throws -> URL? {
        try writeScript(port: port, token: token)
        if includeMessageDelivery { try writeRewakeScript() }

        let settings = try readSettings()
        let backup = try backupSettingsIfNeeded()

        let events = includeToolEvents
            ? harness.defaultHookEvents + HookConfigMerger.toolEvents
            : harness.defaultHookEvents

        // Strip the registrations left by the name this project had before, then
        // install. Two steps and not one because the entries name a path, and the
        // old path is still in `settings.json` on any machine that ran the
        // previous release: leaving it there means a `curl` at a missing script
        // on every turn, silently, since a hook that fails is not an error.
        // Removal is by exact path, so this cannot touch anyone else's hooks.
        let migrated = HookConfigMerger.uninstall(
            from: settings, scriptPaths: legacyScriptPaths
        )

        // Claude Code posts natively; Codex keeps the script for everything,
        // because its hook system has no `http` type to offer. The script is
        // written either way: `SessionStart` and `SessionEnd` still run it, and so
        // does every Codex event.
        let endpoint = harness == .claudeCode
            ? HookConfigMerger.endpoint(port: port, token: token, harness: harness)
            : nil

        let updated = HookConfigMerger.install(
            into: migrated,
            scriptPath: scriptPath,
            rewakeScriptPath: rewakeScriptPath,
            registerMessageDelivery: includeMessageDelivery,
            events: events,
            endpoint: endpoint
        )
        try writeSettings(updated)
        return backup
    }

    /// Removes the registrations from `settings.json`. The script on disk stays:
    /// deleting it while a hook is running it would do nobody any good.
    @discardableResult
    func uninstall() throws -> URL? {
        let settings = try readSettings()
        let backup = try backupSettingsIfNeeded()
        // Both scripts go, always. Leaving the message listener registered after
        // an uninstall would keep spawning a process at the end of every turn for
        // a panel that is no longer there.
        let updated = HookConfigMerger.uninstall(
            from: settings, scriptPaths: [scriptPath, rewakeScriptPath]
        )
        try writeSettings(updated)
        return backup
    }

    // MARK: - I/O

    private func writeScript(port: UInt16, token: String?) throws {
        do {
            try fileManager.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(HookScriptBuilder.script(port: port, harness: harness, token: token).utf8)
                .write(to: scriptURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            throw HookInstallError.scriptWriteFailed(error.localizedDescription)
        }
    }

    /// Writes the message listener next to the traffic light hook.
    ///
    /// The mailbox directory is created here rather than lazily at send time: the
    /// listener refuses to arm without it, and a directory that appears only once
    /// somebody types would mean the first message of every session is the one
    /// that gets lost.
    private func writeRewakeScript() throws {
        do {
            try fileManager.createDirectory(
                at: rewakeScriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Mailbox.ensureDirectory(using: fileManager)
            try Data(RewakeScriptBuilder.script().utf8)
                .write(to: rewakeScriptURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: rewakeScriptURL.path
            )
        } catch {
            throw HookInstallError.scriptWriteFailed(error.localizedDescription)
        }
    }

    private func readSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: settingsURL)
            guard !data.isEmpty else { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookInstallError.unreadableSettings(
                    path: settingsURL.path, reason: "the contents are not a JSON object"
                )
            }
            return object
        } catch let error as HookInstallError {
            throw error
        } catch {
            throw HookInstallError.unreadableSettings(path: settingsURL.path, reason: error.localizedDescription)
        }
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        do {
            // `~/.claude` normally exists, because Claude Code made it. Normally
            // is not always: on a machine where the CLI is installed but has never
            // been run, the write failed with "the folder settings.json doesn't
            // exist" — a message that sends you looking in entirely the wrong
            // place. The scripts had already been written by then, so the
            // installation was half done and reported as failed.
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw HookInstallError.unwritableSettings(path: settingsURL.path, reason: error.localizedDescription)
        }
    }

    /// Copies `settings.json` next to the original with a dated suffix.
    ///
    /// The name carries the date down to the second, and two operations within the
    /// same second collided on it: `copyItem` refuses to overwrite, the error
    /// bubbled all the way up and failed the installation, and the message talked
    /// about a backup while the problem looked like something else. It happens more
    /// often than it sounds — install, uninstall, reinstall in three clicks.
    ///
    /// When the name is taken a counter is appended rather than overwriting: two
    /// backups from the same second can have different contents, and it is the
    /// first one that is worth more.
    private func backupSettingsIfNeeded() throws -> URL? {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let directory = settingsURL.deletingLastPathComponent()

        let backupURL = availableBackupURL(
            in: directory, of: settingsURL.lastPathComponent, stamp: stamp
        )

        do {
            try fileManager.copyItem(at: settingsURL, to: backupURL)
            return backupURL
        } catch {
            throw HookInstallError.unwritableSettings(
                path: settingsURL.path, reason: "backup failed: \(error.localizedDescription)"
            )
        }
    }

    /// The first free name for a backup with that timestamp.
    ///
    /// The limit of twenty attempts is not a carefully chosen threshold: it is a
    /// parachute against an infinite loop should the filesystem always answer
    /// "exists". Reaching it means something is wrong, and the final attempt will
    /// fail with a message instead of spinning forever.
    /// Named after the file it is a copy of, which it was not.
    ///
    /// Both installers share this code and only one of them writes a
    /// `settings.json`: Codex keeps its hooks in `hooks.json`, and its backups
    /// were called `settings.json.lampboard-backup-…` all the same. Nothing was
    /// lost, but somebody reading that directory to recover from a bad install
    /// finds a name for a file that is not there.
    private func availableBackupURL(in directory: URL, of name: String, stamp: String) -> URL {
        let base = "\(name).lampboard-backup-\(stamp)"
        let first = directory.appendingPathComponent(base)
        guard fileManager.fileExists(atPath: first.path) else { return first }

        for suffix in 2...20 {
            let candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base)-21")
    }
}
