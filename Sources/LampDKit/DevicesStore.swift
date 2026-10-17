import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The paired devices: their lines in `authorized_keys`, which are what lets
/// them in, and a register of their names and dates in the state directory.
///
/// `lampd devices add` writes both, on the request of the machine's owner (W3,
/// gesture 17) and from W5 of the Mac (R2: trust goes from the Mac to the
/// nodes); `revoke` takes both away, from the command line or from the phone
/// with its action key. Everything happens under one lock, so a revocation from
/// the phone and an addition at the keyboard cannot interleave.
public struct DevicesStore: Sendable {
    public let paths: LampDPaths

    public init(paths: LampDPaths) { self.paths = paths }

    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let pairedAt: Date
        public var lastSeenAt: Date?
    }

    /// One device as `list` shows it: what the register says and which of its
    /// lines are in the file. A device with lines and no entry, or an entry and
    /// no lines, is said, never hidden.
    public struct Listed: Equatable, Sendable {
        public let id: String
        public let entry: Entry?
        public let roles: [AuthorizedKeys.Role]
    }

    var lockPath: String { paths.stateDirectory + "/devices.lock" }

    // MARK: - Reading

    public func entries() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: paths.devicesFile),
              let entries = try? V1Codec.decoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    public func list() -> [Listed] {
        let text = (try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8)) ?? ""
        let lines = AuthorizedKeys.devices(in: text)
        let registered = entries()
        var out = registered.map { entry in
            Listed(id: entry.id, entry: entry, roles: lines.first { $0.device == entry.id }?.roles ?? [])
        }
        for line in lines where !registered.contains(where: { $0.id == line.device }) {
            out.append(Listed(id: line.device, entry: nil, roles: line.roles))
        }
        return out
    }

    /// The devices as the protocol lists them: those whose lines are in place.
    public func v1Devices() -> [V1Device] {
        list().filter { !$0.roles.isEmpty }.map { listed in
            V1Device(id: listed.id, name: listed.entry?.name ?? listed.id,
                     pairedAt: listed.entry?.pairedAt ?? Date(timeIntervalSince1970: 0),
                     lastSeenAt: listed.entry?.lastSeenAt)
        }
    }

    // MARK: - Changing

    public struct Addition: Sendable {
        public let id: String
        public let name: String
        public let readKey: String
        public let actionKey: String
        public let from: String
        public let command: String
    }

    /// Checks everything a device's lines are made of, before anything is written.
    public static func addition(id: String, name: String, readKey: String, actionKey: String, from: [String],
                                command: String) -> Result<Addition, LampDError> {
        guard AuthorizedKeys.isDeviceId(id) else {
            return .failure(.invalid("\(id) is not a device id: lowercase letters, digits and dashes, up to 40"))
        }
        guard let checkedName = LampDConfig.validName(name) else {
            return .failure(.invalid("a device's name is 1 to 40 characters, without control characters"))
        }
        guard command.hasPrefix("/"), !command.contains(where: { $0 == "\"" || $0 == " " || $0 == "\\" || $0.isNewline }) else {
            return .failure(.invalid("\(command) cannot be the path sshd runs: it must be absolute, without spaces or quotes"))
        }
        let read: String, action: String, networks: String
        switch AuthorizedKeys.publicKey(readKey) {
        case .success(let key): read = key
        case .failure(let error): return .failure(.invalid("the read key: \(error)"))
        }
        switch AuthorizedKeys.publicKey(actionKey) {
        case .success(let key): action = key
        case .failure(let error): return .failure(.invalid("the action key: \(error)"))
        }
        guard read != action else { return .failure(.invalid("the read key and the action key are the same key")) }
        switch AuthorizedKeys.fromList(from) {
        case .success(let list): networks = list
        case .failure(let error): return .failure(error)
        }
        return .success(Addition(id: id, name: checkedName, readKey: read, actionKey: action, from: networks, command: command))
    }

    /// Writes the device's two lines (replacing any it had) and its entry.
    public func add(_ addition: Addition, at now: Date = Date()) throws {
        try LampDPaths.makeDirectory(paths.stateDirectory)
        try FileLock.with(lockPath) {
            let text = try readAuthorizedKeys()
            // A key already in the file under another device, or on a line that
            // is not LampBoard's, would be two owners for one key.
            for key in [addition.readKey, addition.actionKey] {
                for line in text.components(separatedBy: "\n") where line.contains(key) {
                    if let owner = AuthorizedKeys.owner(of: line), owner.device == addition.id { continue }
                    throw LampDError.invalid("this key is already in authorized_keys on another line: nothing was written")
                }
            }
            let lines = AuthorizedKeys.lines(device: addition.id, readKey: addition.readKey, actionKey: addition.actionKey,
                                             from: addition.from, command: addition.command)
            try writeAuthorizedKeys(try AuthorizedKeys.rewrite(text, removing: addition.id, adding: lines))
            var all = entries().filter { $0.id != addition.id }
            all.append(Entry(id: addition.id, name: addition.name, pairedAt: now, lastSeenAt: nil))
            try saveEntries(all)
        }
    }

    /// Takes the device's lines and entry away; `false` when it had neither.
    @discardableResult
    public func revoke(_ id: String) throws -> Bool {
        guard AuthorizedKeys.isDeviceId(id) else { throw LampDError.invalid("\(id) is not a device id") }
        return try FileLock.with(lockPath) {
            let text = try readAuthorizedKeys()
            let rewritten = try AuthorizedKeys.rewrite(text, removing: id, adding: [])
            let had = rewritten != text || entries().contains { $0.id == id }
            if rewritten != text { try writeAuthorizedKeys(rewritten) }
            let all = entries()
            if all.contains(where: { $0.id == id }) { try saveEntries(all.filter { $0.id != id }) }
            return had
        }
    }

    /// When a device last opened a connection, kept to the minute.
    public func seen(_ id: String, at now: Date) {
        guard AuthorizedKeys.isDeviceId(id) else { return }
        try? FileLock.with(lockPath) {
            var all = entries()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            if let last = all[index].lastSeenAt, now.timeIntervalSince(last) < 60 { return }
            all[index].lastSeenAt = now
            try saveEntries(all)
        }
    }

    // MARK: - Files

    private func saveEntries(_ entries: [Entry]) throws {
        try AtomicFile.write(try V1Codec.encoder().encode(entries), to: paths.devicesFile)
    }

    /// The file's text; empty when there is none yet. A symbolic link is
    /// refused rather than followed: writing through it would replace whatever
    /// it points at.
    private func readAuthorizedKeys() throws -> String {
        let path = paths.authorizedKeys
        var info = stat()
        if lstat(path, &info) != 0 { return "" }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw LampDError.invalid("\(path) is not a plain file (a link?): nothing was written")
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw LampDError.io("\(path) could not be read as text: nothing was written")
        }
        return text
    }

    /// Written whole, with the mode the file had (0600 for a new one), in a
    /// `~/.ssh` that is the account's alone: sshd's `StrictModes` refuses keys
    /// in a file or folder others can write.
    private func writeAuthorizedKeys(_ text: String) throws {
        let directory = (paths.authorizedKeys as NSString).deletingLastPathComponent
        if !LampDPaths.isDirectory(directory) { try LampDPaths.makeDirectory(directory, mode: 0o700) }
        var info = stat()
        let mode = lstat(paths.authorizedKeys, &info) == 0 ? Int(info.st_mode & 0o777) & ~0o022 : 0o600
        try AtomicFile.write(Data(text.utf8), to: paths.authorizedKeys, mode: mode)
    }
}
