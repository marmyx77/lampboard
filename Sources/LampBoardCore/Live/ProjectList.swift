import Foundation

/// A project attached to LampBoard (hub-terminale R3): a folder on this Mac or on
/// another machine, kept in the Hub's list with or without a session, so that a
/// session can be started or resumed there without another terminal or VS Code.
public struct AttachedProject: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let path: String
    /// The machine, as in Settings › Other Macs; `nil` is this Mac.
    public let host: String?
    public let addedAt: Date

    public init(path: String, host: String?, addedAt: Date) {
        self.path = PathNormalizer.normalize(path)
        self.host = host?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.addedAt = addedAt
    }

    public var id: String { ProjectList.key(path: path, host: host) }
    public var name: String { (path as NSString).lastPathComponent }
}

/// The Hub's projects: the ones attached, then the folders sessions worked in.
public enum ProjectList {

    /// One project in the list, attached or only seen.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let path: String
        public let host: String?
        /// Kept in the list by the person, not only seen in a session.
        public let attached: Bool
        /// The sessions there now, the most recent first.
        public let sessionIds: [String]
        public let lastActive: Date?

        public var id: String { ProjectList.key(path: path, host: host) }
        public var name: String { (path as NSString).lastPathComponent }
    }

    public static func key(path: String, host: String?) -> String { (host ?? "") + "\u{0}" + path }

    /// Whether a folder can be attached: an absolute path without control
    /// characters, on this Mac or on a machine ssh can be given.
    public static func isValid(path: String, host: String?) -> Bool {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        if let host { return RemoteHostList.isUsable(host) && !host.hasPrefix("-") }
        return true
    }

    /// The list with `project` in it, at the end; the same list when it was
    /// there already; `nil` when it cannot be attached.
    public static func adding(_ project: AttachedProject, to list: [AttachedProject]) -> [AttachedProject]? {
        guard isValid(path: project.path, host: project.host) else { return nil }
        guard !list.contains(where: { $0.id == project.id }) else { return list }
        return list + [project]
    }

    public static func removing(_ id: String, from list: [AttachedProject]) -> [AttachedProject] {
        list.filter { $0.id != id }
    }

    /// The attached projects in their order, then the folders the sessions are
    /// in that nobody attached, the most recent first; each with its sessions.
    public static func entries(attached: [AttachedProject], state: TrafficLightState, seenLimit: Int = 12) -> [Entry] {
        entries(attached: attached,
                sessions: state.sessions.values.map { Seen(id: $0.id, path: $0.workspace.path, host: $0.workspace.host,
                                                            updatedAt: $0.updatedAt) },
                seenLimit: seenLimit)
    }

    /// A session as the list needs it: where it works, and when it last did.
    /// What a device has of a machine's rows (W3 of the mobile plan), without
    /// the Mac's whole state.
    public struct Seen: Equatable, Sendable {
        public let id: String
        public let path: String
        public let host: String?
        public let updatedAt: Date

        public init(id: String, path: String, host: String?, updatedAt: Date) {
            self.id = id
            self.path = path
            self.host = host
            self.updatedAt = updatedAt
        }
    }

    /// The same list from the sessions alone.
    public static func entries(attached: [AttachedProject], sessions seen: [Seen], seenLimit: Int = 12) -> [Entry] {
        var sessions: [String: [Seen]] = [:]
        for session in seen {
            sessions[key(path: session.path, host: session.host), default: []].append(session)
        }
        func entry(path: String, host: String?, attached: Bool) -> Entry {
            let here = (sessions[key(path: path, host: host)] ?? []).sorted { $0.updatedAt > $1.updatedAt }
            return Entry(path: path, host: host, attached: attached, sessionIds: here.map(\.id), lastActive: here.first?.updatedAt)
        }
        let kept = attached.map { entry(path: $0.path, host: $0.host, attached: true) }
        let keys = Set(kept.map(\.id))
        let found = sessions.compactMap { key, list -> Entry? in
            guard !keys.contains(key), let first = list.first else { return nil }
            return entry(path: first.path, host: first.host, attached: false)
        }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        .prefix(seenLimit)
        return kept + found
    }

    public static func decode(_ data: Data) -> [AttachedProject] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = (try? decoder.decode([AttachedProject].self, from: data)) ?? []
        // A file edited by hand keeps what is valid and drops the rest.
        return list.filter { isValid(path: $0.path, host: $0.host) }
    }

    public static func encode(_ list: [AttachedProject]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(list)) ?? Data("[]".utf8)
    }
}
