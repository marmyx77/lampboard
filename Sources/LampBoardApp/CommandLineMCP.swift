import LampBoardCore
import Foundation

/// `lampboard mcp`: the `lampmaster` MCP server Claude Code starts for a session.
///
/// It holds nothing of its own. Each line from Claude Code is answered by
/// `LampMasterMCP`, and each tool call is forwarded to the panel that is
/// already running, which has the cards — the same way the hooks reach it,
/// with the same token. One process per session, started and ended by Claude
/// Code; it costs nothing while nobody calls.
///
/// Claude Code tells it who is asking: `CLAUDE_CODE_SESSION_ID` and the working
/// directory (measured, 4 October 2026). Both travel with every call, so the
/// asker is left out of its own answers and relative paths mean something.
enum LampMasterBridge {

    static func run(port: UInt16) -> Int32 {
        let session = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] ?? ""
        let cwd = FileManager.default.currentDirectoryPath
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let answer = LampMasterMCP.respond(to: line, version: version) { tool, arguments in
                forward(tool: tool, arguments: arguments, session: session, cwd: cwd, port: port)
            }
            if let answer {
                FileHandle.standardOutput.write(Data((answer + "\n").utf8))
            }
        }
        return 0
    }

    /// One tool call, to the running panel and back. Every failure becomes a
    /// tool error the calling model can read and say, never a dead server.
    static func forward(
        tool: LampMasterMCP.Tool, arguments: [String: Any], session: String, cwd: String, port: UInt16
    ) -> (text: String, isError: Bool) {
        let call: [String: Any] = ["tool": tool.rawValue, "arguments": arguments, "session": session, "cwd": cwd]
        guard let body = try? JSONSerialization.data(withJSONObject: call) else { return ("Unreadable arguments.", true) }
        switch LocalClient.lampMasterTool(body, port: port) {
        case .failure(let error):
            return ("LampBoard could not be asked: " + (error.errorDescription ?? "unknown error"), true)
        case .success(let data):
            guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = reply["text"] as? String
            else { return ("LampBoard answered something unreadable.", true) }
            return (text, reply["isError"] as? Bool ?? false)
        }
    }
}
