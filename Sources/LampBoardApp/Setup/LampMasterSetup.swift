import LampBoardCore
import Foundation

/// Puts the `lampmaster` MCP server into Claude Code, and takes it out.
///
/// User scope: every session on this Mac can then ask LampMaster, which is the
/// point — the session that would benefit is never the one you thought of. It
/// is written by `claude mcp add`, read back from `~/.claude.json`, and removed
/// by `claude mcp remove`, here and by `uninstall-hooks`.
enum LampMasterSetup {

    enum Outcome: Equatable {
        case done
        case failed(String)
    }

    static var isRegistered: Bool {
        LampMasterRegistration.registeredCommand(in: try? Data(contentsOf: AppConfig.claudeConfigURL)) != nil
    }

    /// Registers this binary. An entry already there is replaced: the app may
    /// have moved since, and a server that points at a deleted path fails in
    /// every session without saying where.
    static func register(port: UInt16) -> Outcome {
        guard let executable = Bundle.main.executablePath else { return .failed("This app's path is unknown.") }
        if isRegistered, case .failed(let reason) = unregister() { return .failed(reason) }
        return claude(LampMasterRegistration.addArguments(
            executable: executable, port: port, defaultPort: AppConfig.listenPort
        ))
    }

    static func unregister() -> Outcome {
        isRegistered ? claude(LampMasterRegistration.removeArguments) : .done
    }

    /// The same `claude` LampMaster's round runs, found the same way: under
    /// `LAMPBOARD_HOME` only the fake home's.
    private static func claude(_ arguments: [String]) -> Outcome {
        guard let tool = LampMasterRunner.executable() else {
            return .failed("Claude Code's claude command was not found.")
        }
        do {
            // An empty, closed standard input: otherwise the child inherits ours,
            // and a `claude` that reads it would wait on a terminal nobody types in.
            let result = try Command.run(tool, arguments, deadline: 30, input: Data())
            return result.succeeded ? .done : .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let failure as Command.Failure {
            return .failed(failure.explanation)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
