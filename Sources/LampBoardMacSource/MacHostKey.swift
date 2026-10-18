import Crypto
import Foundation
@preconcurrency import NIOSSH

/// The host key of the Mac's server: the one the QR code carries and the phone
/// pins (§2.4). Made once and kept; a new one would make every paired phone
/// refuse the Mac, rightly.
///
/// Where it is kept is the app's choice (`Store`): the app's keychain for a
/// person's Mac, a file of the test home for the gates.
public enum MacHostKey {

    /// Where the key's raw bytes live.
    public protocol Store: Sendable {
        func load() -> Data?
        func save(_ raw: Data) throws
    }

    /// The key in `store`, made and saved the first time.
    public static func loadOrMake(_ store: Store) throws -> NIOSSHPrivateKey {
        if let raw = store.load(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return NIOSSHPrivateKey(ed25519Key: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try store.save(key.rawRepresentation)
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    /// `<algorithm> <base64>`, what the QR code holds.
    public static func openSSH(_ key: NIOSSHPrivateKey) -> String {
        String(openSSHPublicKey: key.publicKey)
    }

    /// `SHA256:<base64 without padding>`, as `ssh-keygen -l` prints it.
    public static func fingerprint(openSSH text: String) -> String {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "SHA256:?" }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// The short form Bonjour's TXT record carries: enough to tell two Macs
    /// apart in a list, never enough to trust one (the full key decides).
    public static func shortFingerprint(openSSH text: String) -> String {
        String(fingerprint(openSSH: text).dropFirst("SHA256:".count).prefix(8))
    }

    /// A file, mode 0600: for test homes and the gates, never a person's Mac.
    public struct FileStore: Store {
        public let path: String

        public init(path: String) { self.path = path }

        public func load() -> Data? {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        public func save(_ raw: Data) throws {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: path, contents: Data((raw.base64EncodedString() + "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw MacSourceError.unavailable("could not write the host key at \(path)")
            }
        }
    }
}
