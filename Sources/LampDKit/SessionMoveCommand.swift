import Foundation
import LampBoardCore

/// `lampd move`: the person moves a session to another project (D184).
///
/// Asked from inside the session — "move yourself to that project" — the
/// command finds its session by walking up to the Claude Code process that runs
/// it; asked from anywhere else, `--session <id>` names it. What it writes is
/// `SessionMoves`' file, read by every screen at its next look.
public struct SessionMoveCommand: Sendable {
    public let paths: LampDPaths

    public init(paths: LampDPaths) { self.paths = paths }

    /// A session on this machine: its id, and the folder its file names.
    public struct Found: Sendable, Equatable {
        public let sessionId: String
        public let started: String
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notInASession
        case noSuchSession(String)
        case notAFolder(String)

        public var description: String {
            switch self {
            case .notInASession:
                return "not run inside a Claude Code session: name one with --session <id>"
            case .noSuchSession(let id): return "no live session \(id) on this machine"
            case .notAFolder(let folder): return "not a folder on this machine: \(folder)"
            }
        }
    }

    /// The session the command runs in, found among its ancestors.
    public func own(from pid: Int = Int(ProcessInfo.processInfo.processIdentifier)) -> Found? {
        SessionMoves.ownSession(from: pid, parent: Self.parent(of:), sessionId: { self.file(pid: $0)?.sessionId })
            .flatMap { file(pid: $0.pid) }
    }

    /// The live session `id` names, from its file.
    public func session(id: String) -> Found? {
        let directory = paths.claudeDirectory + "/sessions"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.lazy
            .compactMap { Int($0.replacingOccurrences(of: ".json", with: "")) }
            .compactMap { self.file(pid: $0) }
            .first { $0.sessionId == id }
    }

    /// Moves `found` to `folder`, relative to `base` when not absolute; the
    /// folder its file names takes the move away.
    public func move(_ found: Found, to folder: String, base: String) throws -> String {
        let absolute = folder.hasPrefix("/") ? folder
            : folder.hasPrefix("~") ? paths.home + folder.dropFirst()
            : base + "/" + folder
        let target = PathNormalizer.normalize(URL(fileURLWithPath: absolute).standardizedFileURL.path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &directory), directory.boolValue else {
            throw Failure.notAFolder(folder)
        }
        try SessionMoves.move(sessionId: found.sessionId, to: target, started: found.started, home: paths.home)
        return target
    }

    public func back(_ found: Found) throws {
        try SessionMoves.back(sessionId: found.sessionId, home: paths.home)
    }

    private func file(pid: Int) -> Found? {
        let path = paths.claudeDirectory + "/sessions/\(pid).json"
        guard let data = FileManager.default.contents(atPath: path),
              let session = try? LiveSessionParser.parse(data: data, modifiedAt: Date()) else { return nil }
        return Found(sessionId: session.sessionId, started: session.cwd)
    }

    /// A process's parent, from `/proc`; `nil` where there is none to read.
    static func parent(of pid: Int) -> Int? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int(fields[1]) : nil
    }
}
