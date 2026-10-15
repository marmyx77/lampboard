#if canImport(CryptoKit)
import CryptoKit
#else
// Linux: the same API, from swift-crypto (Package.swift).
import Crypto
#endif
import Foundation

/// What a notification really says, sealed so that the relay carries it without
/// reading it (§2.8).
///
/// At pairing the phone and each source exchange X25519 public keys. Both sides
/// derive the same key with HKDF-SHA256 over the shared secret, bound to the
/// source and the device, and the source seals the content with
/// ChaCha20-Poly1305. The relay sees a token, a capability and these bytes; the
/// Notification Service Extension opens them, and drops what does not open.
public enum PushEnvelope {

    public static let version = 1

    /// The largest envelope the relay takes, in bytes of its base64 text.
    public static let maxBytes = 3 * 1024

    private static let salt = Array("LampBoard push envelope v1".utf8)

    /// The key one source and one device share. The same on both sides: the
    /// source passes its private key and the device's public one, the device
    /// its own private key and the source's public one.
    public static func key(
        mine: Curve25519.KeyAgreement.PrivateKey, theirs: Curve25519.KeyAgreement.PublicKey,
        source: String, device: String
    ) throws -> SymmetricKey {
        let secret = try mine.sharedSecretFromKeyAgreement(with: theirs)
        // Bound to the pair: a key derived for one source and device seals
        // nothing another pair would open.
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Array("\(source)\n\(device)".utf8), outputByteCount: 32
        )
    }

    /// The content, sealed: base64 of nonce, ciphertext and tag.
    public static func seal(_ content: PushContent, with key: SymmetricKey) throws -> String {
        let plain = try V1Codec.encoder().encode(content)
        let box = try ChaChaPoly.seal(plain, using: key, authenticating: Data(salt))
        return box.combined.base64EncodedString()
    }

    /// The content, or `nil` for anything that does not open with this key:
    /// another source's, a forged one, a damaged one. The extension shows the
    /// placeholder for those and removes the actions.
    public static func open(_ sealed: String, with key: SymmetricKey) -> PushContent? {
        guard let bytes = Data(base64Encoded: sealed),
              let box = try? ChaChaPoly.SealedBox(combined: bytes),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(salt)),
              let content = try? V1Codec.decoder().decode(PushContent.self, from: plain),
              content.v == version
        else { return nil }
        return content
    }
}

/// The real text of a notification and what places it in time.
public struct PushContent: Codable, Equatable, Sendable {
    public let v: Int
    /// The source that sent it, and its number among that source's envelopes:
    /// what lets the extension drop one it has already seen.
    public let source: String
    public let seq: Int
    public let at: Date
    public let title: String
    public let body: String
    /// The row it is about, for the tap.
    public let session: String?

    public init(source: String, seq: Int, at: Date, title: String, body: String, session: String?) {
        self.v = PushEnvelope.version
        self.source = source
        self.seq = seq
        self.at = at
        self.title = title
        self.body = body
        self.session = session
    }
}

/// The extension's memory of what it has shown: per source, the last number.
///
/// A relay can repeat an envelope or hold one back; neither may ring twice, or
/// ring for a moment long gone.
public struct PushReplayGuard: Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        case fresh
        /// Its number is not past the last one shown from that source.
        case replayed
        /// Older than `maxAge`, or from further in the future than a clock drifts.
        case stale
    }

    public let maxAge: TimeInterval
    public private(set) var lastSeq: [String: Int] = [:]

    public init(maxAge: TimeInterval = 15 * 60) {
        self.maxAge = maxAge
    }

    public mutating func admit(_ content: PushContent, at now: Date) -> Verdict {
        let age = now.timeIntervalSince(content.at)
        guard age <= maxAge, age >= -60 else { return .stale }
        if let last = lastSeq[content.source], content.seq <= last { return .replayed }
        lastSeq[content.source] = content.seq
        return .fresh
    }
}
