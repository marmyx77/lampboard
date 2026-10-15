import Crypto
import Foundation
import NIOSSH

/// Where a machine is: an address, a port, the account the keys open.
public struct NodeEndpoint: Equatable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public let user: String

    public init(host: String, port: Int = 22, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }

    public var description: String { "\(user)@\(host):\(port)" }
}

/// A machine's ssh host key, as OpenSSH writes it: `<algorithm> <base64>`.
///
/// The key decides who the machine is, never the address (§2.5 of the mobile
/// plan): the same key answering on the LAN and on the tailnet is the same
/// machine, and an address that answers with another key is an error said out
/// loud, never a fallback.
public struct NodeHostKey: Hashable, Sendable, CustomStringConvertible {
    /// `<algorithm> <base64>`, without the comment.
    public let openSSH: String

    /// Reads one line of a `.pub` or `known_hosts`-style key; the comment, if
    /// any, is dropped.
    public init(openSSH line: String) throws {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard parts.count >= 2 else { throw NodeLinkError.badKey("not an OpenSSH public key") }
        let text = "\(parts[0]) \(parts[1])"
        do {
            _ = try NIOSSHPublicKey(openSSHPublicKey: text)
        } catch {
            throw NodeLinkError.badKey("not an OpenSSH public key: \(error)")
        }
        openSSH = text
    }

    init(_ key: NIOSSHPublicKey) {
        openSSH = String(openSSHPublicKey: key)
    }

    /// `SHA256:<base64 without padding>`, the form `ssh-keygen -l` prints and
    /// the Mac shows next to the QR code.
    public var fingerprint: String {
        let parts = openSSH.split(separator: " ")
        guard parts.count == 2, let blob = Data(base64Encoded: String(parts[1])) else { return "SHA256:?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    public var description: String { openSSH }
}

/// How the host key of one connection is judged.
///
/// There is no "accept anything": trusting a key the first time it is seen is
/// a choice the caller makes by name, once, and the key that was presented
/// comes back to be pinned for every connection after (TOFU, made explicit).
/// In the app the key usually comes from the QR code or from the Mac's own
/// `known_hosts`, and `firstUse` is never needed.
public enum HostKeyTrust: Equatable, Sendable {
    /// Only this key.
    case pinned(NodeHostKey)
    /// Whatever the machine presents, this time only, so that it can be pinned.
    case firstUse
}

/// The verdict on a presented host key. Pure, so it is tested without a network.
public enum HostKeyVerdict: Equatable, Sendable {
    case accepted(NodeHostKey)
    case refused(presented: NodeHostKey, expected: NodeHostKey)

    public init(trust: HostKeyTrust, presented: NodeHostKey) {
        switch trust {
        case .firstUse:
            self = .accepted(presented)
        case .pinned(let expected):
            self = presented == expected ? .accepted(presented) : .refused(presented: presented, expected: expected)
        }
    }
}

/// The key that only reads (§2.4): it opens the `v1` channel and nothing else.
/// On a node `authorized_keys` forces `lampd v1-stdio` for it whatever it asks;
/// the Mac's server accepts nothing but `v1` from it. On the phone it lives in
/// the Keychain without biometry, because the widgets and the app's return from
/// the background use it.
///
/// A type of its own, not a flag: `ReadConnection` has no way to run a command,
/// so a read key reaching for one does not compile.
public struct ReadKey: @unchecked Sendable {
    let key: P256.Signing.PrivateKey

    public init(_ key: P256.Signing.PrivateKey) { self.key = key }

    public init(rawRepresentation: Data) throws {
        do { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) } catch {
            throw NodeLinkError.badKey("not a P-256 private key")
        }
    }

    public static func generate() -> ReadKey { ReadKey(P256.Signing.PrivateKey()) }

    public var rawRepresentation: Data { key.rawRepresentation }

    /// `ecdsa-sha2-nistp256 <base64>`, for `authorized_keys` and pairing.
    public var publicKey: String { String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: key).publicKey) }
}

/// The key that acts (§2.4): `v1` and commands; later the terminal, files and
/// the devices. On the phone it lives in the Secure Enclave behind Face ID
/// (Q6); here it is the same P-256 key in software, as on the simulator and on
/// Linux, where there is no enclave to hold it.
public struct ActionKey: @unchecked Sendable {
    let key: P256.Signing.PrivateKey

    public init(_ key: P256.Signing.PrivateKey) { self.key = key }

    public init(rawRepresentation: Data) throws {
        do { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) } catch {
            throw NodeLinkError.badKey("not a P-256 private key")
        }
    }

    public static func generate() -> ActionKey { ActionKey(P256.Signing.PrivateKey()) }

    public var rawRepresentation: Data { key.rawRepresentation }

    public var publicKey: String { String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: key).publicKey) }
}
