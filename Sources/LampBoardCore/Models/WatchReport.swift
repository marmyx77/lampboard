import Foundation

/// What `lampboard watch` tells the panel about the command it runs (D70).
///
/// Posted to `POST /watch` behind the token, by the panel's own binary, so its
/// rows can never be made by a hook or a page. Bounded like the mod's reports:
/// an id of a known shape, a name of one printable line, an absolute folder.
public struct WatchReport: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        case started
        case ended(exitCode: Int32)
    }

    public let id: String
    public let name: String
    public let cwd: String
    public let phase: Phase

    public init(id: String, name: String, cwd: String, phase: Phase) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.phase = phase
    }

    /// The row's session id: its own prefix, so it never meets a real one.
    public var sessionId: String { "watch-" + id }

    public static let version = 1

    public enum Failure: Error, Equatable {
        case unreadable
    }

    public static func decode(_ data: Data) throws -> WatchReport {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.v == version,
              let id = wire.id, (6...40).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }),
              let rawName = wire.name, let name = ModReport.detail(rawName),
              let cwd = wire.cwd, cwd.hasPrefix("/"), cwd.count <= 4096, isPlainPath(cwd)
        else { throw Failure.unreadable }
        switch wire.phase {
        case "start":
            return WatchReport(id: id, name: name, cwd: cwd, phase: .started)
        case "end":
            guard let code = wire.exit else { throw Failure.unreadable }
            return WatchReport(id: id, name: name, cwd: cwd, phase: .ended(exitCode: code))
        default:
            throw Failure.unreadable
        }
    }

    /// No control, format or separator character: the folder is drawn on a row
    /// and a card, where a bidi override or a newline could disguise it.
    static func isPlainPath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// At most this many command rows: a cron job running `lampboard watch` every
    /// minute would otherwise fill the column for twelve hours. The oldest
    /// finished one makes room.
    public static let maxRows = 20

    /// The JSON `lampboard watch` posts.
    public func encoded() -> Data {
        var object: [String: Any] = ["v": Self.version, "id": id, "name": name, "cwd": cwd]
        switch phase {
        case .started: object["phase"] = "start"
        case .ended(let code): object["phase"] = "end"; object["exit"] = Int(code)
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The row as this report leaves it: yellow while it runs, green on 0, red
    /// otherwise, with the code in its message.
    public func session(updating old: SessionState?, at now: Date) -> SessionState {
        let base = old ?? SessionState(
            id: sessionId, status: .working, workspace: Workspace(path: cwd),
            updatedAt: now, statusSince: now, harness: .command,
            entrypoint: "lampboard-watch", origin: .terminal, title: name
        )
        switch phase {
        case .started:
            return base.with(status: .working, at: now).with(failureReason: nil).with(lastMessage: nil)
        case .ended(let code):
            let took = CompactDuration.label(seconds: now.timeIntervalSince(base.statusSince))
            return code == 0
                ? base.with(status: .ready, at: now).with(failureReason: nil).with(lastMessage: "exited 0 after \(took)")
                : base.with(status: .failed, at: now).with(failureReason: .commandFailed)
                    .with(lastMessage: "exited with \(code) after \(took)")
        }
    }

    private struct Wire: Decodable {
        let v: Int?
        let id: String?
        let name: String?
        let cwd: String?
        let phase: String?
        let exit: Int32?
    }
}
