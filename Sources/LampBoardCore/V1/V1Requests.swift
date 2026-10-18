import Foundation

/// What a client asks a source (§2.2). Each request is one JSON object with an
/// `op`, and an `id` the answer repeats as `re`.
public enum V1Request: Equatable, Sendable {
    /// The first thing on every connection: who is asking, and what it speaks.
    case hello(protocol: Int, client: String)
    /// The whole state, once. What a widget asks.
    case state
    /// The event stream. `since` is the last event the client holds, in the
    /// journal it names; `nil` means "I hold nothing": the source sends its
    /// state first, then everything after it, with no gap between the two.
    case events(since: Int?, journal: String?, ping: TimeInterval?)
    /// The last messages of one session's conversation.
    case transcript(session: String, limit: Int?)
    /// One of the low-power actions, and nothing else (R4).
    case command(V1Command)
    /// Where to send this device's notifications, and how to seal them.
    case pushRegister(V1PushRegistration)
    /// The paired devices: only with the action key.
    case devices(V1DevicesRequest)

    /// The `op` each request travels under.
    public var op: String {
        switch self {
        case .hello: return "hello"
        case .state: return "state"
        case .events: return "events"
        case .transcript: return "transcript"
        case .command: return "cmd"
        case .pushRegister: return "push.register"
        case .devices: return "devices"
        }
    }

    public static let ops: Set<String> = ["hello", "state", "events", "transcript", "cmd", "push.register", "devices"]
}

/// The low-power actions a phone may ask of a source (§2.2). Each is a choice
/// about how a row is shown; none starts, stops or answers anything, so none
/// needs the action key. Anything else is refused before the source sees it.
public enum V1Action: String, Codable, Sendable, CaseIterable {
    case markSeen, markUnread, rename, hide, mute, calmBlink, focus, order, dismiss

    /// The actions about one row, which name it.
    public var needsSession: Bool {
        switch self {
        case .focus, .order: return false
        default: return true
        }
    }
}

public struct V1Command: Codable, Equatable, Sendable {
    public let action: V1Action
    public let session: String?
    /// `rename`: the new name; empty clears it.
    public let name: String?
    /// `hide` and `mute`: on or off.
    public let on: Bool?
    /// `order`: the rows' ids in the order wanted.
    public let ids: [String]?

    public init(action: V1Action, session: String? = nil, name: String? = nil, on: Bool? = nil, ids: [String]? = nil) {
        self.action = action
        self.session = session
        self.name = name
        self.on = on
        self.ids = ids
    }

    public static let maxName = 120
    /// The same name in bytes. A character can be any number of them — a
    /// letter under two thousand accents is one character — so characters
    /// alone do not bound what a source keeps.
    public static let maxNameBytes = 1024
    public static let maxIds = 1000

    /// Why the command cannot be carried out as written, or `nil`. Checked by
    /// the service before any source sees it: a source implements the actions,
    /// it does not re-validate them.
    public var problem: String? {
        if action.needsSession {
            guard let session, V1Validation.isSessionId(session) else { return "\(action.rawValue) needs a session id" }
        }
        switch action {
        case .rename:
            guard let name else { return "rename needs a name" }
            if name.count > Self.maxName || name.utf8.count > Self.maxNameBytes {
                return "a name is at most \(Self.maxName) characters and \(Self.maxNameBytes) bytes"
            }
            if V1Validation.hasControlCharacters(name) { return "a name has no control characters" }
        case .hide, .mute:
            if on == nil { return "\(action.rawValue) needs on" }
        case .focus:
            if let session, !V1Validation.isSessionId(session) { return "focus names a session id or none" }
        case .order:
            guard let ids, ids.count <= Self.maxIds, ids.allSatisfy(V1Validation.isSessionId) else {
                return "order needs up to \(Self.maxIds) session ids"
            }
        default:
            break
        }
        return nil
    }
}

/// What a phone registers with each source it is paired with (§2.8).
public struct V1PushRegistration: Codable, Equatable, Sendable {
    /// The capability the relay gave this device's token.
    public let capability: String
    /// The APNs device token, hex.
    public let token: String
    public let environment: APNsEnvironment
    /// The device's X25519 public key for the envelopes, base64.
    public let envelopeKey: String
    /// The Live Activity's push token, when one is running.
    public let liveActivityToken: String?
    /// The relay's capability for that token (`/v1/capability/liveactivity`).
    public let liveActivityCapability: String?
    /// What this device wants to hear (§2.9; Settings › Notifications).
    public let preferences: V1PushPreferences?

    public init(capability: String, token: String, environment: APNsEnvironment, envelopeKey: String,
                liveActivityToken: String? = nil, liveActivityCapability: String? = nil,
                preferences: V1PushPreferences? = nil) {
        self.capability = capability
        self.token = token
        self.environment = environment
        self.envelopeKey = envelopeKey
        self.liveActivityToken = liveActivityToken
        self.liveActivityCapability = liveActivityCapability
        self.preferences = preferences
    }

    public var problem: String? {
        if !V1Validation.isHexToken(token) { return "token is not an APNs token" }
        if let live = liveActivityToken, !V1Validation.isHexToken(live) { return "liveActivityToken is not an APNs token" }
        if (liveActivityToken == nil) != (liveActivityCapability == nil) {
            return "a Live Activity token needs its capability, and the other way round"
        }
        if let cap = liveActivityCapability, cap.isEmpty || cap.count > 512 || V1Validation.hasControlCharacters(cap) {
            return "liveActivityCapability is not one"
        }
        if let problem = preferences?.problem { return problem }
        if capability.isEmpty || capability.count > 512 || V1Validation.hasControlCharacters(capability) {
            return "capability is not one"
        }
        guard let key = Data(base64Encoded: envelopeKey), key.count == 32 else { return "envelopeKey is not an X25519 key" }
        return nil
    }
}

/// What one device wants to hear from a source (§2.9).
public struct V1PushPreferences: Codable, Equatable, Sendable {
    /// Notifications at all: off still keeps the memory of what was already
    /// so (D9), so turning them on is not a burst.
    public let enabled: Bool
    /// A turn finished with an answer: only when asked for.
    public let finished: Bool
    /// Everything silent until then.
    public let mutedUntil: Date?
    /// Projects never to alert for, by the row's folder (`path`) or name.
    public let mutedProjects: [String]

    public static let maxProjects = 200

    public init(enabled: Bool = true, finished: Bool = false, mutedUntil: Date? = nil, mutedProjects: [String] = []) {
        self.enabled = enabled
        self.finished = finished
        self.mutedUntil = mutedUntil
        self.mutedProjects = mutedProjects
    }

    public static let standard = V1PushPreferences()

    public var problem: String? {
        if mutedProjects.count > Self.maxProjects { return "too many muted projects" }
        if mutedProjects.contains(where: { $0.isEmpty || $0.count > 400 || V1Validation.hasControlCharacters($0) }) {
            return "a muted project is not a name"
        }
        return nil
    }

    private enum Keys: String, CodingKey { case enabled, finished, mutedUntil, mutedProjects }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        mutedUntil = try container.decodeIfPresent(Date.self, forKey: .mutedUntil)
        mutedProjects = try container.decodeIfPresent([String].self, forKey: .mutedProjects) ?? []
    }
}

public enum APNsEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

public struct V1DevicesRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case list, revoke }
    public let action: Action
    public let device: String?

    public init(action: Action, device: String? = nil) {
        self.action = action
        self.device = device
    }

    public var problem: String? {
        if action == .revoke, !(device.map(V1Validation.isSessionId) ?? false) { return "revoke needs a device id" }
        return nil
    }
}

/// The shapes a source accepts, checked once for every source.
public enum V1Validation {
    /// A session or device id: 1 to 200 characters out of ASCII letters, digits
    /// and `-_.:`, starting with a letter or a digit — so never `.`, `..` or a
    /// hidden name, whatever a source later builds from it. A Claude Code
    /// session id is a UUID; a Codex one too.
    public static func isSessionId(_ value: String) -> Bool {
        guard (1...200).contains(value.unicodeScalars.count), let first = value.unicodeScalars.first,
              isASCIIAlphanumeric(first) else { return false }
        return value.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || "-_.:".unicodeScalars.contains($0) }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    public static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// An APNs token: an even number of hex digits, 32 to 200 bytes' worth.
    public static func isHexToken(_ value: String) -> Bool {
        guard (64...400).contains(value.count), value.count % 2 == 0 else { return false }
        return value.unicodeScalars.allSatisfy { $0.properties.isASCIIHexDigit }
    }
}
