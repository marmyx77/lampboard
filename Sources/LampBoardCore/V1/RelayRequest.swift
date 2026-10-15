import Foundation

/// What the push relay gave one device's token (§2.8): proof that whoever asked
/// held the token, which the relay checks again by recomputing it. A source can
/// write to that token and to no other.
public struct RelayCapability: Codable, Equatable, Sendable {
    /// The relay's HMAC over token, environment and version, base64.
    public let cap: String
    public let token: String
    public let environment: APNsEnvironment
    public let version: Int

    public init(cap: String, token: String, environment: APNsEnvironment, version: Int = 1) {
        self.cap = cap
        self.token = token
        self.environment = environment
        self.version = version
    }
}

/// The three kinds of push a source sends (§2.8).
public enum PushKind: String, Codable, Sendable {
    /// A notification, with `mutable-content` so the extension can open it.
    case alert
    /// State for the widgets, shown to nobody.
    case background
    /// An update of the Live Activity.
    case liveactivity
}

/// One push as a source hands it to the relay: the capability, the kind, the
/// priority and the envelope — and nothing a person wrote.
public struct RelayPushRequest: Codable, Equatable, Sendable {
    public let cap: String
    public let token: String
    public let environment: APNsEnvironment
    public let kind: PushKind
    /// 10 sends at once and wakes the screen; 5 lets APNs choose. Ten only for
    /// what cannot wait: a new permission question (§2.8, point 4).
    public let priority: Int
    public let envelope: String

    public enum Refusal: Error, Equatable, Sendable {
        /// Over `PushEnvelope.maxBytes`: the relay would refuse it anyway.
        case tooLarge
        /// The request's bytes contain what the envelope was meant to hide.
        case readable
        /// APNs takes a background push only at priority 5.
        case badPriority
    }

    /// The request for `sealed`, checked before it leaves: the source refuses to
    /// send a push the relay could read. `content` is what was sealed, here only
    /// so the check has something to look for.
    public static func make(
        capability: RelayCapability, kind: PushKind, urgent: Bool, sealed: String, content: PushContent
    ) throws -> RelayPushRequest {
        let priority = urgent ? 10 : 5
        if kind == .background && urgent { throw Refusal.badPriority }
        guard sealed.utf8.count <= PushEnvelope.maxBytes else { throw Refusal.tooLarge }
        // A sealed box is base64 of a nonce, the ciphertext and a tag. What the
        // person would read, or the row it is about, anywhere in its bytes is a
        // seal that did not happen. (Four random bytes match a given four with a
        // chance of one in four billion per position: no false alarm in practice.)
        guard let bytes = Data(base64Encoded: sealed), bytes.count >= 12 + 16 else { throw Refusal.readable }
        let secrets = [content.title, content.body, content.session ?? ""].filter { $0.utf8.count >= 4 }
        if secrets.contains(where: { Self.contains(Array(bytes), Array($0.utf8)) }) { throw Refusal.readable }
        return RelayPushRequest(
            cap: capability.cap, token: capability.token, environment: capability.environment,
            kind: kind, priority: priority, envelope: sealed
        )
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
