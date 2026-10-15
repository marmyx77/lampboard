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
    /// The source that sent it, as it names itself: shown, never trusted. The
    /// extension knows which pair an envelope belongs to from the key that
    /// opened it (`PushReplayGuard.admit(_:from:at:)`).
    public let source: String
    /// The count the number belongs to, and the number: what lets the extension
    /// drop an envelope it has already seen. A source that starts again with
    /// nothing kept starts a new journal at 1, like its `v1` journal.
    public let journal: String
    public let seq: Int
    public let at: Date
    public let title: String
    public let body: String
    /// The row it is about, for the tap.
    public let session: String?

    public init(source: String, journal: String, seq: Int, at: Date, title: String, body: String, session: String?) {
        self.v = PushEnvelope.version
        self.source = source
        self.journal = journal
        self.seq = seq
        self.at = at
        self.title = title
        self.body = body
        self.session = session
    }
}

/// The extension's memory of what it has shown: per pair, the journal, the last
/// number and its time.
///
/// A relay can repeat an envelope or hold one back; neither may ring twice, or
/// ring for a moment long gone. Two things are kept apart on purpose:
/// - **The pair, not the content's word.** The guard is keyed on the pair whose
///   key opened the envelope. Keyed on what the content says of itself, one
///   paired source could name another and push its count past anything the
///   other will send: silence for that one.
/// - **A new journal is a new count.** A source restarted with nothing kept
///   numbers from 1 again. Its envelopes are fresh when they are newer than the
///   last one shown from that pair; an old journal's envelope, held back and
///   sent after, is not.
public struct PushReplayGuard: Codable, Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        case fresh
        /// Its number is not past the last one shown from that pair, or it
        /// belongs to a count that has since been replaced.
        case replayed
        /// Older than `maxAge`, or from further in the future than a clock drifts.
        case stale
    }

    public struct Mark: Codable, Equatable, Sendable {
        public let journal: String
        public let seq: Int
        public let at: Date
    }

    public let maxAge: TimeInterval
    public private(set) var last: [String: Mark] = [:]

    public init(maxAge: TimeInterval = 15 * 60) {
        self.maxAge = maxAge
    }

    /// `content`, opened with the key of `pair`, at `now`.
    public mutating func admit(_ content: PushContent, from pair: String, at now: Date) -> Verdict {
        let age = now.timeIntervalSince(content.at)
        guard age <= maxAge, age >= -60 else { return .stale }
        if let mark = last[pair] {
            if content.journal == mark.journal {
                if content.seq <= mark.seq { return .replayed }
            } else if content.at <= mark.at {
                return .replayed
            }
        }
        // The time only moves forward: it is what judges the next journal.
        let shown = last[pair].map { $0.journal == content.journal ? max($0.at, content.at) : content.at } ?? content.at
        last[pair] = Mark(journal: content.journal, seq: content.seq, at: shown)
        return .fresh
    }
}
