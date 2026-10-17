import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Where `lampd` reads and writes, worked out once from the environment.
///
/// Everything hangs off one home: `LAMPBOARD_HOME` when it is set (the checks
/// and the fake node give every run a home of its own), `HOME` otherwise. Claude
/// Code's files are read under it and nothing of Claude Code's is ever written;
/// `lampd`'s own state lives in `~/.local/state/lampd` (ADR-65 point 6), its
/// configuration in `~/.config/lampd`, and the socket the read key's command
/// reaches in the runtime directory, which only the account can enter.
public struct LampDPaths: Equatable, Sendable {
    public let home: String
    public let stateDirectory: String
    public let configDirectory: String
    public let runtimeDirectory: String

    public init(home: String, stateDirectory: String, configDirectory: String, runtimeDirectory: String) {
        self.home = home
        self.stateDirectory = stateDirectory
        self.configDirectory = configDirectory
        self.runtimeDirectory = runtimeDirectory
    }

    /// The paths of this process, from its environment.
    ///
    /// The runtime directory is `$XDG_RUNTIME_DIR/lampd`. A forced command run
    /// by an sshd without PAM has no `XDG_RUNTIME_DIR`; it then looks where
    /// systemd puts the account's (`/run/user/<uid>`), and only on a machine
    /// without one falls back to the state directory — the same rule in the
    /// service and in the command, so both find the same socket.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> LampDPaths {
        let home = environment[AppConfig.homeOverrideVariable].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        let state = home + "/.local/state/lampd"
        let runtimeBase: String
        if let xdg = environment["XDG_RUNTIME_DIR"], !xdg.isEmpty, environment[AppConfig.homeOverrideVariable] == nil {
            runtimeBase = xdg
        } else if environment[AppConfig.homeOverrideVariable] == nil, isDirectory("/run/user/\(getuid())") {
            runtimeBase = "/run/user/\(getuid())"
        } else {
            runtimeBase = state + "/run"
        }
        return LampDPaths(
            home: home, stateDirectory: state, configDirectory: home + "/.config/lampd",
            runtimeDirectory: runtimeBase + "/lampd"
        )
    }

    /// The socket the service listens on and `lampd v1-stdio` connects to.
    public var socket: String { runtimeDirectory + "/v1.sock" }
    public var configFile: String { configDirectory + "/config.json" }
    public var journalFile: String { stateDirectory + "/journal.jsonl" }
    public var rowsFile: String { stateDirectory + "/rows.json" }
    public var preferencesFile: String { stateDirectory + "/preferences.json" }
    public var devicesFile: String { stateDirectory + "/devices.json" }
    public var contractFile: String { stateDirectory + "/contract.json" }
    public var allowanceFile: String { stateDirectory + "/allowance.json" }
    public var logFile: String { stateDirectory + "/lampd.log" }
    /// A file the checks drop to stop the service's loop on purpose, honoured
    /// only when the unit says so (`LAMPD_TEST_HOOKS=1`): the watchdog's bite.
    public var blockLoopFile: String { stateDirectory + "/block-loop" }
    public var claudeDirectory: String { home + "/.claude" }
    public var authorizedKeys: String { home + "/.ssh/authorized_keys" }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Makes `path` and its parents, the last one with `mode`.
    public static func makeDirectory(_ path: String, mode: Int = 0o700) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: mode])
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}

/// Writes a file whole or not at all: a temporary file beside it, then a rename.
///
/// A reader in another process — the service, a forced command, the next
/// start — sees the old contents or the new ones, never half of each.
public enum AtomicFile {
    public static func write(_ data: Data, to path: String, mode: Int = 0o600) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = directory + "/.\((path as NSString).lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: mode]) else {
            throw LampDError.io("could not write \(temporary)")
        }
        guard rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw LampDError.io("could not replace \(path): \(reason)")
        }
    }
}

/// An advisory lock on a file of its own, held for the length of a closure:
/// the service, a forced command reading files and a `lampd devices` run may
/// all write the same file, and each reads it again under the lock.
public enum FileLock {
    public static func with<T>(_ path: String, _ body: () throws -> T) throws -> T {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw LampDError.io("could not open the lock \(path)") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw LampDError.io("could not lock \(path)") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

public enum LampDError: Error, Equatable, CustomStringConvertible {
    case io(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .io(let text), .invalid(let text): return text
        }
    }
}
