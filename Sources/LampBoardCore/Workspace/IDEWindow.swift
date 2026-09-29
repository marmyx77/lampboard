import Foundation

/// An IDE window hosting a Claude Code connection, reconstructed from a lock file
/// in `~/.claude/ide/`.
public struct IDEWindow: Sendable, Equatable {
    /// Root folders open in the window.
    public let workspaceFolders: [String]

    /// IDE name declared in the lock (`Visual Studio Code`, `Cursor`, …).
    public let ideName: String

    /// PID of the IDE process. Careful: VS Code writes the same PID into every
    /// lock, one per window — so it does not identify the window, it only tells
    /// you whether the IDE is still alive.
    public let pid: Int

    /// Modification date of the lock, used to discard orphaned files.
    public let lockModifiedAt: Date

    /// The same folders as the filesystem spells them, one for one with
    /// `workspaceFolders`: links followed, capitals settled.
    ///
    /// Needed because the two sides of the match do not come from one source. The
    /// window's folders are what the editor was asked to open, and a folder opened
    /// through a link keeps the link's name; the session's `cwd` is the process's
    /// working directory, which the kernel hands back resolved. Measured on 29
    /// September 2026: a window on `~/Development/livetranscribe`, a link to
    /// `~/Development/callduo`, hosted a session reporting `callduo`; nothing
    /// matched, the row fell back to being a terminal session, and its click
    /// raised nothing for five days. The match now accepts either spelling, and
    /// the row keeps the **window's** one — it is the name in the title the click
    /// looks for.
    ///
    /// Equal to `workspaceFolders` until somebody who may touch the disk fills it
    /// in (`resolvingLinks()`): the pure parser does not.
    public let resolvedFolders: [String]

    public init(
        workspaceFolders: [String],
        ideName: String,
        pid: Int,
        lockModifiedAt: Date,
        resolvedFolders: [String]? = nil
    ) {
        self.workspaceFolders = workspaceFolders.map(PathNormalizer.normalize)
        let resolved = resolvedFolders?.map(PathNormalizer.normalize) ?? []
        self.resolvedFolders = resolved.count == self.workspaceFolders.count ? resolved : self.workspaceFolders
        self.ideName = ideName
        self.pid = pid
        self.lockModifiedAt = lockModifiedAt
    }

    /// This window with its folders resolved on disk. Touches the filesystem.
    public func resolvingLinks() -> IDEWindow {
        IDEWindow(
            workspaceFolders: workspaceFolders,
            ideName: ideName,
            pid: pid,
            lockModifiedAt: lockModifiedAt,
            resolvedFolders: workspaceFolders.map(CanonicalPath.of)
        )
    }

    /// The editor that wrote this lock, if we know it.
    public var kind: IDEKind? {
        IDEKind.matching(declaredName: ideName)
    }

    /// `true` when we know how to bring this window to the front.
    ///
    /// The question used to be "is this Visual Studio Code?", and that answer
    /// discarded the forks that do have the Claude Code extension installed. Now
    /// it is "can we raise it?", which is what actually needs knowing.
    public var isSupported: Bool { kind != nil }

    /// `true` when the window belongs to Visual Studio Code.
    public var isVSCode: Bool { kind == .visualStudioCode }

    /// `true` when this lock still describes a window that exists.
    ///
    /// The question is **liveness, not age**. A lock file is written once, when the
    /// window connects, and never touched again — so its timestamp measures how
    /// long the window has been open, which is the opposite of what it was being
    /// used for. Windows left open for a week or two are normal, and every one of
    /// them silently disappeared from the column on its eighth day: five projects
    /// at once, on the machine where this was found.
    ///
    /// The lock carries the editor's `pid`, and it always did. If that process is
    /// running, the window is real however old the file is.
    ///
    /// Age remains the fallback for a lock with no usable pid — which is what the
    /// rule was always *for*, since locks are not always removed when a window
    /// closes.
    ///
    /// - Parameter alivePids: editor processes confirmed running.
    public func isUsable(
        at now: Date,
        alivePids: Set<Int>,
        maxAge: TimeInterval = AppConfig.ideLockMaxAge
    ) -> Bool {
        if pid > 0 { return alivePids.contains(pid) }
        return now.timeIntervalSince(lockModifiedAt) <= maxAge
    }
}

/// Errors reading a lock file.
public enum IDELockError: Error, Equatable {
    case invalidJSON
    case missingWorkspaceFolders
}

/// Decodes the JSON of a Claude Code lock file.
public enum IDELockParser {
    public static func parse(
        data: Data,
        modifiedAt: Date
    ) throws -> IDEWindow {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
            let object = parsed as? [String: Any]
        else {
            throw IDELockError.invalidJSON
        }

        guard
            let folders = object["workspaceFolders"] as? [Any]
        else {
            throw IDELockError.missingWorkspaceFolders
        }

        let paths = folders.compactMap { $0 as? String }.filter { $0.hasPrefix("/") }
        guard !paths.isEmpty else {
            throw IDELockError.missingWorkspaceFolders
        }

        return IDEWindow(
            workspaceFolders: paths,
            ideName: (object["ideName"] as? String) ?? "",
            pid: (object["pid"] as? Int) ?? 0,
            lockModifiedAt: modifiedAt
        )
    }
}
