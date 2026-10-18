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
    /// What the news is: what the extension picks the category and the
    /// interruption level from, once the envelope has opened (§2.9). `nil` in
    /// an envelope of a source one version behind: an alert with no actions.
    public let event: PushEvent?
    /// The source's rows by colour at `at`: the badge (summed over sources by
    /// the extension, §2.8 point 3), the widget and the Live Activity.
    public let counts: PushCounts?
    /// Delivered without a sound: the other devices' copy, two minutes after
    /// the one last used rang and nobody opened it (Q9).
    public let quiet: Bool?

    public init(source: String, journal: String, seq: Int, at: Date, title: String, body: String, session: String?,
                event: PushEvent? = nil, counts: PushCounts? = nil, quiet: Bool? = nil) {
        self.v = PushEnvelope.version
        self.source = source
        self.journal = journal
        self.seq = seq
        self.at = at
        self.title = title
        self.body = body
        self.session = session
        self.event = event
        self.counts = counts
        self.quiet = quiet
    }
}

/// The kinds of news an envelope carries.
public enum PushEvent: String, Codable, Sendable, CaseIterable {
    /// A session waits for the person: a permission or a question. Time
    /// Sensitive, with Deny before Open.
    case waiting
    /// A turn died.
    case failed
    /// A turn finished, for a device that asked to hear it.
    case finished
    /// What waited while the person was in one session, in one line (G1).
    case summary
    /// The counts alone, for the widget and the Live Activity.
    case counts

    /// The notification category the extension gives a verified alert.
    public var category: String? {
        switch self {
        case .waiting: return PushCategories.waiting
        case .failed, .finished, .summary: return PushCategories.session
        case .counts: return nil
        }
    }

    /// Only a session waiting for the person breaks through Focus (§2.9).
    public var timeSensitive: Bool { self == .waiting }
}

/// The categories the app registers and the extension assigns.
public enum PushCategories {
    public static let waiting = "lampboard.waiting"
    public static let session = "lampboard.session"
    /// Actions, by identifier.
    public static let deny = "lampboard.deny"
    public static let open = "lampboard.open"
    public static let silence = "lampboard.silence"
}

/// One source's rows by colour.
public struct PushCounts: Codable, Equatable, Sendable {
    /// Amber: waiting for the person.
    public let waiting: Int
    /// Red.
    public let failed: Int
    /// Green, an answer not yet read.
    public let ready: Int
    /// Yellow and blue: at work.
    public let working: Int

    public init(waiting: Int, failed: Int, ready: Int, working: Int) {
        self.waiting = waiting
        self.failed = failed
        self.ready = ready
        self.working = working
    }

    public static let zero = PushCounts(waiting: 0, failed: 0, ready: 0, working: 0)

    /// What the badge counts: the rows that want the person.
    public var wanting: Int { waiting + failed + ready }

    /// The counts of rows, by their status words on the wire.
    public init(statuses: [String]) {
        var waiting = 0, failed = 0, ready = 0, working = 0
        for status in statuses {
            switch SessionStatus(rawValue: status) {
            case .awaiting?: waiting += 1
            case .failed?: failed += 1
            case .ready?: ready += 1
            case .working?, .waiting?: working += 1
            default: break
            }
        }
        self.init(waiting: waiting, failed: failed, ready: ready, working: working)
    }

    public static func + (a: PushCounts, b: PushCounts) -> PushCounts {
        PushCounts(waiting: a.waiting + b.waiting, failed: a.failed + b.failed,
                   ready: a.ready + b.ready, working: a.working + b.working)
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
