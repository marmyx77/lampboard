import Foundation
import LampBoardCore

/// What the Mac told this machine on `lampd mac-link` (W5, §2.9, §2.12): where
/// the person is (Q8), the Mac's settings the phone needs here, and whether the
/// panel's own choices were merged in already. Kept on disk (`mac.json`, 0600)
/// so a restart forgets none of it, and written by whichever process took the
/// line: the service, or `lampd mac-link` itself while the service is down.
public struct MacState: Codable, Equatable, Sendable {
    public var presence: MacPresence?
    public var presenceAt: Date?
    public var settings: MacNodeSettings?
    public var settingsAt: Date?
    /// When the panel's choices were merged (once; a second migration line is
    /// merged again, which changes nothing the node wrote later).
    public var migratedAt: Date?

    public init() {}

    /// Whether the person is at the Mac now: a fresh `here`, said by a Mac
    /// whose link is up or went within `MacNodeLink.linkGrace`. Anything else —
    /// away, asleep, a Mac never heard, one silent too long — is away.
    public func isHere(at now: Date, linkSeenAt: Date?) -> Bool {
        guard presence == .here, let presenceAt, now.timeIntervalSince(presenceAt) <= MacNodeLink.presenceStaleAfter else {
            return false
        }
        guard let linkSeenAt else { return false }
        return now.timeIntervalSince(linkSeenAt) <= MacNodeLink.linkGrace
    }

    /// A line from the Mac, already checked (`MacToNode.problem`), applied to
    /// what is kept here. Commands and migrations change the choices, not this.
    public mutating func take(_ line: MacToNode) {
        if let presence = line.presence {
            self.presence = presence
            presenceAt = line.at
        }
        if let settings = line.settings {
            self.settings = settings
            settingsAt = line.at
        }
        if line.migration != nil { migratedAt = line.at }
    }

    /// How `status` and `doctor` say it.
    public func describe(at now: Date, linkSeenAt: Date?) -> String {
        guard let presence, let presenceAt else { return "the Mac has said nothing here" }
        let age = Int(now.timeIntervalSince(presenceAt))
        let link = linkSeenAt.map { "link seen \(Int(now.timeIntervalSince($0))) s ago" } ?? "no link since the start"
        let verdict = isHere(at: now, linkSeenAt: linkSeenAt) ? "at the Mac: the phone stays quiet" : "away: the phone rings"
        return "\(presence.rawValue), said \(age) s ago, \(link): \(verdict)"
    }
}

/// `mac.json`, read and written under a lock.
public struct MacStateFile: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public func load() -> MacState {
        guard let data = FileManager.default.contents(atPath: path) else { return MacState() }
        return (try? V1Codec.decoder().decode(MacState.self, from: data)) ?? MacState()
    }

    @discardableResult
    public func update(_ change: (inout MacState) -> Void) throws -> MacState {
        try FileLock.with(path + ".lock") {
            var state = load()
            change(&state)
            try AtomicFile.write(try V1Codec.encoder().encode(state), to: path)
            return state
        }
    }
}

/// A line from the Mac carried out on the files, the same whichever process
/// takes it: the service (which then publishes) or `lampd mac-link` while the
/// service is down (the service reads the files at its next start).
public enum MacLines {

    /// What the line changed: `nil` when it was refused, with why.
    public static func apply(_ line: MacToNode, paths: LampDPaths) -> Result<MacToNode, LampDError> {
        if let problem = line.problem { return .failure(.invalid(problem)) }
        do {
            try LampDPaths.makeDirectory(paths.stateDirectory)
            try MacStateFile(path: paths.macStateFile).update { $0.take(line) }
            let preferences = PreferencesFile(path: paths.preferencesFile)
            if let command = line.command {
                try preferences.update { $0.apply(command, at: line.at) }
            }
            if let migration = line.migration {
                // The node's copy first: at a tie, what the phone did stays.
                try preferences.update { $0 = $0.merged(with: migration.preferences) }
            }
            return .success(line)
        } catch let error as LampDError {
            return .failure(error)
        } catch {
            return .failure(.io("\(error)"))
        }
    }
}
