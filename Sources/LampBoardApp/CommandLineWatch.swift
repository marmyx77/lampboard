import LampBoardCore
import Foundation

/// `lampboard watch [--name N] -- <command>`: any long job becomes a row (D70).
///
/// The command runs as a child of this process, in this terminal: its input,
/// output and exit code are the command's own, so `lampboard watch -- make` can
/// stand in for `make` in a script without changing what the script sees. The
/// panel is told when it starts and how it ended; when the panel is not there,
/// the command still runs and nothing else changes.
enum CommandLineWatch {

    static func run(_ arguments: [String], port: UInt16) -> Int32 {
        guard let parsed = parse(arguments) else {
            FileHandle.standardError.write(Data("usage: lampboard watch [--name N] -- <command> [arguments…]\n".utf8))
            return 2
        }
        let cwd = FileManager.default.currentDirectoryPath
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        // The program's name, not the whole line: arguments carry passwords
        // (`-p hunter2`) that no masking can know. `--name` says more on purpose.
        let name = parsed.name ?? URL(fileURLWithPath: parsed.command[0]).lastPathComponent
        let start = WatchReport(id: String(id), name: name, cwd: cwd, phase: .started)
        let heard = tell(start, port: port)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = parsed.command
        // Inherited, not piped: the command talks to this terminal as if it
        // had been run directly.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        // Ctrl-C reaches the command as it would have, and this process lives
        // to report how it ended. A handler and not SIG_IGN: an ignored signal
        // is inherited across exec, and the command would stop hearing Ctrl-C.
        signal(SIGINT) { _ in }
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("lampboard watch: \(error.localizedDescription)\n".utf8))
            _ = tell(WatchReport(id: start.id, name: name, cwd: cwd, phase: .ended(exitCode: 127)), port: port)
            return 127
        }
        // A terminal closed or a `kill` sent to this wrapper reaches the command
        // too, and the end is still reported; an empty handler keeps this process
        // alive to do it, and is not inherited by the command as an ignore would be.
        let forwarded = [SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
            signal(sig) { _ in }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(process.processIdentifier, sig) }
            source.resume()
            return source
        }
        process.waitUntilExit()
        forwarded.forEach { $0.cancel() }
        let code = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        if heard { _ = tell(WatchReport(id: start.id, name: name, cwd: cwd, phase: .ended(exitCode: code)), port: port) }
        return code
    }

    /// `--name N`, then `--`, then the command. The `--` is required: without
    /// it a command's own flags could be read as this tool's.
    static func parse(_ arguments: [String]) -> (name: String?, command: [String])? {
        guard let dashes = arguments.firstIndex(of: "--") else { return nil }
        let options = Array(arguments[..<dashes])
        let command = Array(arguments[arguments.index(after: dashes)...])
        guard !command.isEmpty else { return nil }
        var name: String?
        if let flag = options.firstIndex(of: "--name") {
            guard options.indices.contains(flag + 1) else { return nil }
            name = options[flag + 1]
        }
        return (name, command)
    }

    /// Whether the panel heard. Said once, on the error stream, when it did
    /// not: the command's own output stays the command's.
    private static func tell(_ report: WatchReport, port: UInt16) -> Bool {
        switch LocalClient.watch(report, port: port) {
        case .success:
            return true
        case .failure(let error):
            FileHandle.standardError.write(Data(
                "lampboard watch: the panel did not hear (\(error.errorDescription ?? "unknown")); running anyway\n".utf8
            ))
            return false
        }
    }
}
