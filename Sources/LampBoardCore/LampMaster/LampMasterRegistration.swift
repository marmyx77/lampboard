import Foundation

/// How the `lampmaster` MCP server is registered in Claude Code, and how to
/// tell whether it is.
///
/// Through Claude Code's own `claude mcp add --scope user`, never by writing
/// `~/.claude.json`: that file is Claude Code's, rewritten by it all day, and a
/// second writer is a race nobody would see until a setting vanished.
///
/// Whether it is registered is read from the file, not asked with
/// `claude mcp get`: measured on 4 October 2026, `get` **starts** the server to
/// check its health, and a status check must not launch anything.
public enum LampMasterRegistration {

    public static let name = LampMasterMCP.serverName

    /// - Parameters:
    ///   - executable: this app's binary, which `mcp` turns into the server.
    ///   - port: added only when it is not the default, so the usual entry stays
    ///     the shortest one.
    public static func addArguments(executable: String, port: UInt16, defaultPort: UInt16) -> [String] {
        ["mcp", "add", "--scope", "user", name, "--", executable, "mcp"]
            + (port == defaultPort ? [] : ["--port", String(port)])
    }

    public static let removeArguments = ["mcp", "remove", "--scope", "user", name]

    /// The registered command, from `~/.claude.json`, or `nil` when there is none.
    public static func registeredCommand(in config: Data?) -> String? {
        guard let config,
              let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any],
              let entry = servers[name] as? [String: Any]
        else { return nil }
        return entry["command"] as? String ?? ""
    }
}
