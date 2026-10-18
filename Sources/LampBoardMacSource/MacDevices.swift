import Foundation
import LampBoardCore
@preconcurrency import NIOSSH

/// The iPhones and iPads this Mac paired (§2.4, §2.12: the Mac keeps the list).
///
/// One file, `devices.json`, mode 0600 in a folder 0700, written whole and
/// renamed into place. It is read again whenever it changed on disk, so a
/// device forgotten in Settings is refused at its very next connection, and so
/// is one removed by hand.
public final class MacDevices: @unchecked Sendable {

    public struct Device: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// `ecdsa-sha2-nistp256 <base64>`, as `String(openSSHPublicKey:)` writes it.
        public let readKey: String
        public let actionKey: String
        public let pairedAt: Date
        public var lastSeenAt: Date?
        /// The relay's capability for this device (W4), kept for the relay client.
        public var relayCapability: String?

        /// `SHA256:…` of each key, what Settings shows beside the name.
        public var readFingerprint: String { MacHostKey.fingerprint(openSSH: readKey) }
        public var actionFingerprint: String { MacHostKey.fingerprint(openSSH: actionKey) }
    }

    public let path: String
    private let lock = NSLock()
    private var cached: [Device] = []
    private var cachedStamp: Date?

    /// - Parameter directory: where `devices.json` lives; made 0700 if missing.
    public init(directory: String) {
        path = directory + "/devices.json"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    public var all: [Device] { locked { load() } }

    public var isEmpty: Bool { all.isEmpty }

    /// The device and the role a public key logs in with, or `nil` for a key
    /// this Mac never paired.
    public func role(of key: NIOSSHPublicKey) -> (device: String, role: V1Role)? {
        let text = String(openSSHPublicKey: key)
        return locked {
            for device in load() {
                if device.readKey == text { return (device.id, .read) }
                if device.actionKey == text { return (device.id, .action) }
            }
            return nil
        }
    }

    /// The same, for a key as OpenSSH writes it.
    public func role(ofOpenSSH text: String) -> (device: String, role: V1Role)? {
        guard let canonical = Self.canonical(text), let key = try? NIOSSHPublicKey(openSSHPublicKey: canonical) else { return nil }
        return role(of: key)
    }

    /// Adds the device a pairing asked for, under a new id.
    public func add(_ request: MacPairingRequest, at now: Date) throws -> Device {
        if let problem = request.problem { throw MacSourceError.refused(problem) }
        guard let read = Self.canonical(request.readKey), let action = Self.canonical(request.actionKey) else {
            throw MacSourceError.refused("the keys are not OpenSSH public keys")
        }
        return try locked {
            var devices = load()
            guard !devices.contains(where: { [$0.readKey, $0.actionKey].contains(read) || [$0.readKey, $0.actionKey].contains(action) }) else {
                throw MacSourceError.refused("one of these keys is already paired: forget that device first")
            }
            var id: String
            repeat { id = "dev-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)) } while devices.contains { $0.id == id }
            let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let device = Device(id: id, name: name, readKey: read, actionKey: action, pairedAt: now,
                                lastSeenAt: nil, relayCapability: request.relayCapability)
            devices.append(device)
            try save(devices)
            return device
        }
    }

    /// Forgets one device; `false` when there was no such device.
    @discardableResult
    public func revoke(_ id: String) throws -> Bool {
        try locked {
            var devices = load()
            guard devices.contains(where: { $0.id == id }) else { return false }
            devices.removeAll { $0.id == id }
            try save(devices)
            return true
        }
    }

    /// «Forget all»: no device can come back without pairing again.
    public func forgetAll() throws {
        try locked { try save([]) }
    }

    /// When a device last connected, kept in memory and written at most once a minute.
    public func seen(_ id: String, at now: Date) {
        locked {
            var devices = load()
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            let last = devices[index].lastSeenAt
            devices[index].lastSeenAt = now
            if last.map({ now.timeIntervalSince($0) > 60 }) ?? true { try? save(devices) } else { cached = devices }
        }
    }

    /// As `v1` reports them.
    public var v1Devices: [V1Device] {
        all.map { V1Device(id: $0.id, name: $0.name, pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt) }
    }

    /// The canonical text of a P-256 OpenSSH public key, or `nil`.
    static func canonical(_ text: String) -> String? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ecdsa-sha2-nistp256",
              let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(parts[0]) \(parts[1])") else { return nil }
        return String(openSSHPublicKey: key)
    }

    // MARK: - The file

    private func load() -> [Device] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if stamp == cachedStamp, stamp != nil { return cached }
        guard let data = FileManager.default.contents(atPath: path),
              let devices = try? Self.decoder.decode([Device].self, from: data) else {
            cached = []
            cachedStamp = stamp
            return []
        }
        cached = devices
        cachedStamp = stamp
        return devices
    }

    private func save(_ devices: [Device]) throws {
        let data = try Self.encoder.encode(devices)
        let temporary = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MacSourceError.unavailable("could not write \(temporary)")
        }
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw MacSourceError.unavailable("could not replace \(path)")
        }
        cached = devices
        cachedStamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public enum MacSourceError: Error, Equatable, CustomStringConvertible {
    case refused(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .refused(let why), .unavailable(let why): return why
        }
    }
}
