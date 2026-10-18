import Foundation
import LampBoardCore

/// What the person may set for `lampd`, in `~/.config/lampd/config.json`.
///
/// Small on purpose, and every key optional: a missing file is the defaults,
/// and a key this build does not know is ignored rather than refused, so a
/// configuration written by a newer `lampd` does not stop an older one.
public struct LampDConfig: Equatable, Sendable {
    /// The name the machine goes by on the phone. Never the host name: real
    /// host names carry personal data (S-P), so the default says only what it is.
    public var name: String
    /// Seconds between two looks at Claude Code's files.
    public var probeInterval: TimeInterval
    /// Whether the service asks the usage service for this machine's allowance
    /// on its own. Off by default: it is the one request `lampd` would make to
    /// anything but the push relay, and ADR-65 point 10 names only the relay.
    /// `lampd usage` asks once, when the person runs it.
    public var allowance: Bool
    /// Whether the contract timer may run the live probe with Claude Code
    /// (Q22): it starts real sessions, so it stays off until it is turned on.
    public var contractLive: Bool
    /// Whether the service sends notifications through the push relay (W4).
    public var notifications: Bool
    /// The push relay: the public one unless a check points at its own.
    public var relay: URL

    public static let defaultName = "Linux"
    public static let defaultProbeInterval: TimeInterval = 5

    public init(name: String = defaultName, probeInterval: TimeInterval = defaultProbeInterval,
                allowance: Bool = false, contractLive: Bool = false, notifications: Bool = true,
                relay: URL = RelayClient.production) {
        self.name = name
        self.probeInterval = probeInterval
        self.allowance = allowance
        self.contractLive = contractLive
        self.notifications = notifications
        self.relay = relay
    }

    /// The configuration in `path`, the defaults when there is none, and a
    /// sentence when there is one that cannot be read.
    public static func load(_ path: String) -> (config: LampDConfig, problem: String?) {
        guard let data = FileManager.default.contents(atPath: path) else { return (LampDConfig(), nil) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (LampDConfig(), "\(path) is not a JSON object: the defaults are in use")
        }
        var config = LampDConfig()
        var problems: [String] = []
        if let name = object["name"] as? String {
            if let checked = validName(name) { config.name = checked } else { problems.append("name") }
        }
        if let interval = (object["probeInterval"] as? NSNumber)?.doubleValue {
            if (1...60).contains(interval) { config.probeInterval = interval } else { problems.append("probeInterval") }
        }
        if let allowance = object["allowance"] as? Bool { config.allowance = allowance }
        if let live = object["contractLive"] as? Bool { config.contractLive = live }
        if let notifications = object["notifications"] as? Bool { config.notifications = notifications }
        if let relay = object["relay"] as? String {
            if let url = validRelay(relay) { config.relay = url } else { problems.append("relay") }
        }
        let problem = problems.isEmpty ? nil : "\(path): \(problems.joined(separator: ", ")) not valid, the default is in use"
        return (config, problem)
    }

    /// A machine's name as the phone shows it: 1 to 40 characters, no control
    /// characters, no leading or trailing space.
    public static func validName(_ name: String) -> String? {
        let trimmed = name.trimmed
        guard (1...40).contains(trimmed.count), !V1Validation.hasControlCharacters(trimmed) else { return nil }
        return trimmed
    }

    /// A relay address: `https`, or `http` only to this machine or a private
    /// network (a check's own relay). Never a path, a query or a user.
    public static func validRelay(_ text: String) -> URL? {
        guard let url = URL(string: text), let host = url.host, url.user == nil, url.query == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        if url.scheme == "https" { return url }
        guard url.scheme == "http" else { return nil }
        let privateHost = host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.")
            || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        return privateHost ? url : nil
    }

    /// The client the service sends with, or `nil` when notifications are off.
    public func relayClient(transport: RelayTransport = CurlRelayTransport()) -> RelayClient? {
        notifications ? RelayClient(base: relay, transport: transport) : nil
    }

    public var identity: V1SourceIdentity { V1SourceIdentity(kind: .node, name: name) }
}
