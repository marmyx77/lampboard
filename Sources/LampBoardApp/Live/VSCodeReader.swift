import Foundation
import LampBoardCore

/// Where «Like my VS Code» reads from (D144): the VS Code on this Mac, its
/// profile in use, its colour theme's file, and the chat's font.
enum VSCodeReader {

    struct Result {
        let theme: LiveTheme
        /// The chat font's fixed-width sibling, when this Mac has one.
        let fontFamily: String?
    }

    private static var user: URL {
        AppConfig.homeDirectory.appendingPathComponent("Library/Application Support/Code/User", isDirectory: true)
    }

    private static let bundledExtensions = URL(fileURLWithPath:
        "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions", isDirectory: true)

    /// `nil` without a VS Code whose colours can be read.
    static func read() -> Result? {
        let settings = activeSettings()
        let themeName = (settings["workbench.colorTheme"] as? String) ?? defaultThemeName()
        let themeColors = themeName.flatMap(themeColors(named:)) ?? [:]
        guard let colors = VSCodeTheme.colors(settings: settings, themeName: themeName, themeColors: themeColors) else { return nil }
        let font = VSCodeTheme.monoSibling(of: settings["chat.fontFamily"] as? String, among: LiveFonts.families())
        return Result(theme: VSCodeTheme.liveTheme(colors), fontFamily: font)
    }

    /// The families VS Code's chat is set in, as its settings list them.
    static func chatFontFamilies() -> [String] {
        guard let value = activeSettings()["chat.fontFamily"] as? String else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }

    // MARK: - The profile in use

    /// The default settings, under the profile whose editor background is the
    /// one VS Code last drew (`themeBackground` in its own storage): the profile
    /// of the window last open. Without one, the default settings alone.
    private static func activeSettings() -> [String: Any] {
        let base = load(user.appendingPathComponent("settings.json")) ?? [:]
        let storage = load(user.appendingPathComponent("globalStorage/storage.json")) ?? [:]
        let drawn = (storage["themeBackground"] as? String).flatMap(VSCodeTheme.hex6)
        let profiles = (try? FileManager.default.contentsOfDirectory(
            at: user.appendingPathComponent("profiles", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
        let candidates = profiles.compactMap { load($0.appendingPathComponent("settings.json")) }
        let chosen = candidates.first { profile in
            guard let drawn else { return false }
            let custom = profile["workbench.colorCustomizations"] as? [String: Any]
            return (custom?["editor.background"] as? String).flatMap(VSCodeTheme.hex6) == drawn
        }
        guard let chosen else { return base }
        return base.merging(chosen) { _, profile in profile }
    }

    /// VS Code's own default, by the kind of theme it last drew.
    private static func defaultThemeName() -> String? {
        let storage = load(user.appendingPathComponent("globalStorage/storage.json")) ?? [:]
        guard let kind = storage["theme"] as? String else { return nil }
        return kind.contains("dark") ? "Dark Modern" : "Light Modern"
    }

    // MARK: - The colour theme's file

    /// The theme's `colors`, following its `include` chain, from the bundled
    /// extensions and the ones installed.
    private static func themeColors(named name: String) -> [String: String]? {
        let installed = AppConfig.homeDirectory.appendingPathComponent(".vscode/extensions", isDirectory: true)
        for root in [bundledExtensions, installed] {
            let extensions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in extensions {
                guard let package = load(folder.appendingPathComponent("package.json")),
                      let contributes = package["contributes"] as? [String: Any],
                      let themes = contributes["themes"] as? [[String: Any]] else { continue }
                for theme in themes where (theme["id"] as? String) == name || (theme["label"] as? String) == name {
                    guard let path = theme["path"] as? String else { continue }
                    return colors(of: folder.appendingPathComponent(path).standardizedFileURL, depth: 0)
                }
            }
        }
        return nil
    }

    private static func colors(of file: URL, depth: Int) -> [String: String] {
        guard depth < 5, let theme = load(file) else { return [:] }
        var colors: [String: String] = [:]
        if let include = theme["include"] as? String {
            colors = self.colors(of: file.deletingLastPathComponent().appendingPathComponent(include).standardizedFileURL,
                                 depth: depth + 1)
        }
        for (key, value) in theme["colors"] as? [String: Any] ?? [:] {
            if let value = value as? String { colors[key] = value }
        }
        return colors
    }

    private static func load(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return VSCodeTheme.parse(text)
    }
}
