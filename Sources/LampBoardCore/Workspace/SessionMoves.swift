import Foundation

/// A session the person moved to another project (D184).
///
/// D183 keeps a session in the folder its file names, wherever its `cwd` goes,
/// because a `cd` made for the work is not a move. When the person does mean
/// it — "this one belongs with the other project now" — that is said here: one
/// file per session, `~/.lampboard/moves/<session id>`, holding the folder, on
/// the machine the session runs on. Written there because that machine's files
/// are what every screen reads: `lampd` for the phone, the Mac's probe over
/// ssh, the phone's own probe where there is no `lampd`. A preference kept on
/// one screen would move the row on that screen only, which is the
/// disagreement D183 was about.
///
/// The session's own `cwd` is never rewritten: its transcript is filed under
/// it, and that is where a resume has to start.
public enum SessionMoves {

    /// Where the moves of a machine whose home is `home` are kept.
    public static func directory(home: String) -> String { home + "/.lampboard/moves" }

    /// A session id fit to be a file name: what Claude Code writes, a UUID, and
    /// nothing that could climb out of the directory.
    public static func isSafe(sessionId: String) -> Bool {
        !sessionId.isEmpty && sessionId.count <= 128
            && sessionId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The file that says where `sessionId` was moved; `nil` for an id that is
    /// not fit to name one.
    public static func path(home: String, sessionId: String) -> String? {
        isSafe(sessionId: sessionId) ? directory(home: home) + "/" + sessionId : nil
    }

    /// The folder `sessionId` was moved to, or `nil`: never moved, or a file
    /// that does not hold an absolute path.
    public static func folder(home: String, sessionId: String) -> String? {
        guard let path = path(home: home, sessionId: sessionId),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return folder(from: String(decoding: data, as: UTF8.self))
    }

    /// What a move file says, read as the probe reads it: the first line,
    /// trimmed, when it is an absolute path.
    public static func folder(from contents: String) -> String? {
        let line = contents.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
        return line.hasPrefix("/") ? PathNormalizer.normalize(line) : nil
    }

    /// Records that `sessionId` now belongs to `folder`. Moving it back to the
    /// folder its file names is taking the move away, which `started` says.
    public static func move(sessionId: String, to folder: String, started: String?, home: String) throws {
        guard let path = path(home: home, sessionId: sessionId) else { throw SessionMoveError.unsafeSession(sessionId) }
        let target = PathNormalizer.normalize(folder)
        guard target.hasPrefix("/") else { throw SessionMoveError.notAFolder(folder) }
        if let started, PathNormalizer.normalize(started) == target {
            try back(sessionId: sessionId, home: home)
            return
        }
        try FileManager.default.createDirectory(atPath: directory(home: home), withIntermediateDirectories: true)
        try Data((target + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Takes the move away: the session belongs to the folder its file names
    /// again. Nothing to take away is not an error.
    public static func back(sessionId: String, home: String) throws {
        guard let path = path(home: home, sessionId: sessionId) else { throw SessionMoveError.unsafeSession(sessionId) }
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    /// The session a command belongs to: the nearest of its ancestors that has a
    /// session file. Claude Code runs a command as a child of its own process,
    /// so a session asked to move itself finds itself this way, without being
    /// told its id.
    /// - Parameters:
    ///   - start: the command's own pid.
    ///   - parent: a process's parent, `nil` when it cannot be read.
    ///   - sessionId: the session id of the file a pid has, `nil` when none.
    public static func ownSession(
        from start: Int, parent: (Int) -> Int?, sessionId: (Int) -> String?
    ) -> (pid: Int, sessionId: String)? {
        var pid = start
        for _ in 0..<32 {
            if let id = sessionId(pid) { return (pid, id) }
            guard let next = parent(pid), next > 1, next != pid else { return nil }
            pid = next
        }
        return nil
    }
}

public enum SessionMoveError: Error, Equatable, CustomStringConvertible {
    case unsafeSession(String)
    case notAFolder(String)

    public var description: String {
        switch self {
        case .unsafeSession(let id): return "not a session id: \(id)"
        case .notAFolder(let folder): return "not a folder on this machine: \(folder)"
        }
    }
}
