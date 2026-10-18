import Foundation
import LampBoardCore

/// The preferences file, read and written under a lock: the service and a
/// forced command reading files may both write it.
public struct PreferencesFile: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public func load() -> RowPreferences {
        guard let data = FileManager.default.contents(atPath: path) else { return RowPreferences() }
        return RowPreferences.decode(data)
    }

    /// Reads the file again under the lock, applies `change`, writes it back,
    /// and returns what was written.
    @discardableResult
    public func update(_ change: (inout RowPreferences) -> Void) throws -> RowPreferences {
        try FileLock.with(path + ".lock") {
            var preferences = load()
            change(&preferences)
            try AtomicFile.write(try preferences.encoded(), to: path)
            return preferences
        }
    }
}
