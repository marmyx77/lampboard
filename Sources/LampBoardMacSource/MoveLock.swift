import Foundation
import LampBoardCore

/// The Move's lock on this Mac (H1.5-3, W3c): the same folder a device's Move
/// takes through the bridge, `~/.lampboard/moving/<session>`, so that a Move
/// from the panel and one from the phone cannot both end the same VS Code
/// process and start two writers. The same rules as `RemoteMove.lockedScript`:
/// `mkdir` decides; a lock older than `RemoteMove.lockLasts` is taken over by
/// exactly one Move (a rename only one of them can win).
public enum MoveLock {

    public static func path(session: String, home: String) -> String {
        home + "/" + RemoteMove.lockFolder + "/" + session
    }

    /// Takes the lock; `false` when another Move holds it, or the id is not one.
    public static func take(session: String, home: String, now: Date = Date()) -> Bool {
        guard ModReport.isSessionId(session), !session.hasPrefix("-") else { return false }
        let lock = path(session: session, home: home)
        let parent = (lock as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if mkdir(lock, 0o700) == 0 { return true }
        guard errno == EEXIST,
              let made = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date,
              now.timeIntervalSince(made) >= RemoteMove.lockLasts else { return false }
        let stale = lock + ".stale.\(getpid())"
        guard rename(lock, stale) == 0 else { return false }
        rmdir(stale)
        return mkdir(lock, 0o700) == 0
    }

    /// Lets go, once the conversation goes on elsewhere or nothing was ended.
    public static func release(session: String, home: String) {
        guard ModReport.isSessionId(session), !session.hasPrefix("-") else { return }
        rmdir(path(session: session, home: home))
    }
}
