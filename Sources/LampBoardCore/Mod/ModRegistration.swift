import Foundation

/// How the companion mod gets into Claude Code, and how to tell that it is.
///
/// Through Claude Code's own `claude plugin` commands, never by writing its
/// settings: measured on 4 October 2026, `plugin install` writes
/// `enabledPlugins` and `extraKnownMarketplaces` into `~/.claude/settings.json`
/// and keeps its own records under `~/.claude/plugins/`, and a second writer of
/// those files is the race D63 already refused for the MCP server. Both
/// commands honour `HOME`, which is what lets the tests use a fake one.
public enum ModRegistration {

    public static let marketplace = "lampboard"
    public static let plugin = "lampboard@lampboard"

    /// Mods are generally available from this release on. Below it the hooks
    /// alone keep the panel working, as they do anyway (D65).
    public static let firstRelease = ReleaseVersion(major: 2, minor: 1, patch: 287)

    /// `nil` (unreadable) reads as able, like `NativeHookSupport`: Claude Code
    /// updates itself, and an install that fails says why.
    public static func isSupported(by version: ReleaseVersion?) -> Bool {
        guard let version else { return true }
        return version >= firstRelease
    }

    /// The steps that install the mod from a folder holding `ModFiles.all`.
    public static func installSteps(folder: String) -> [[String]] {
        [
            ["plugin", "marketplace", "add", folder],
            ["plugin", "install", plugin, "--scope", "user"],
        ]
    }

    /// The steps that take it out, the marketplace with it: a marketplace left
    /// declared points every Claude Code at a folder that may be gone.
    public static let uninstallSteps: [[String]] = [
        ["plugin", "uninstall", plugin, "--scope", "user"],
        ["plugin", "marketplace", "remove", marketplace],
    ]

    /// Whether `~/.claude/settings.json` has the mod switched on.
    public static func isEnabled(settings: Data?) -> Bool {
        guard let settings,
              let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let enabled = object["enabledPlugins"] as? [String: Any]
        else { return false }
        return enabled[plugin] as? Bool == true
    }

    /// Whether Claude Code still has the `lampboard` marketplace declared, in the
    /// settings `marketplace add` wrote or in its own list of marketplaces.
    public static func isMarketplaceDeclared(settings: Data?, known: Data?) -> Bool {
        let declared = settings
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["extraKnownMarketplaces"] as? [String: Any] }?[marketplace] != nil
        let listed = known
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[marketplace] != nil
        return declared || listed
    }

    /// The version installed, from `~/.claude/plugins/installed_plugins.json`;
    /// `nil` when it is not there or the file reads otherwise than expected.
    ///
    /// The file's shape is Claude Code's and unannounced, so it is searched
    /// rather than walked: any object naming this plugin's id with a version.
    public static func installedVersion(records: Data?) -> String? {
        guard let records, let object = try? JSONSerialization.jsonObject(with: records) else { return nil }
        return version(in: object)
    }

    private static func version(in node: Any) -> String? {
        if let dictionary = node as? [String: Any] {
            if let entry = dictionary[plugin] {
                if let found = versionField(entry) { return found }
            }
            if (dictionary["id"] as? String) == plugin, let found = dictionary["version"] as? String { return found }
            for value in dictionary.values { if let found = version(in: value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = version(in: value) { return found } }
        }
        return nil
    }

    private static func versionField(_ entry: Any) -> String? {
        if let dictionary = entry as? [String: Any] { return dictionary["version"] as? String }
        if let array = entry as? [Any] { return array.lazy.compactMap(versionField).first }
        return nil
    }
}
