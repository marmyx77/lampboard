import Foundation

/// What the Agent View keeps about a background session, beyond its live file
/// (§5.14, AV2): `~/.claude/jobs/<id>/state.json`.
///
/// Two of its fields are worth a row's second line. `detail` is the one-line
/// summary Claude Code writes of what the session has done — better than the
/// first line of its last answer, which is what a row reads otherwise. `needs`
/// is what a blocked session is waiting for, kept only while `tempo` says it is
/// blocked: the file keeps the last one after the block is over.
///
/// The directory's name is the id `claude attach` takes, and it goes into a
/// command the person pastes into a shell; an id that is not plain letters,
/// digits and dashes is not a job.
public struct BackgroundJob: Sendable, Equatable {
    /// Past this a summary or a need is cut: the row has room for forty
    /// characters, the tooltip for a few lines.
    public static let maxLength = 200

    public let id: String
    public let sessionId: String
    public let summary: String?
    public let needs: String?

    public init(id: String, sessionId: String, summary: String?, needs: String?) {
        self.id = id
        self.sessionId = sessionId
        self.summary = summary
        self.needs = needs
    }

    /// What reopens the session in a terminal; copied, never run (D104).
    public var attachCommand: String { "claude attach \(id)" }
}

public enum BackgroundJobParser {

    /// The `tempo` of a session waiting for its person.
    static let blockedTempo = "blocked"

    /// The job in `data`, or `nil` when it names no session or its id is unfit
    /// for a shell.
    public static func parse(data: Data, id: String) -> BackgroundJob? {
        guard isSafe(id: id),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = (object["sessionId"] as? String)?.trimmed.nilIfEmpty
        else { return nil }
        let blocked = (object["tempo"] as? String) == blockedTempo
        return BackgroundJob(
            id: id,
            sessionId: sessionId,
            summary: line(object["detail"]),
            needs: blocked ? line(object["needs"]) : nil
        )
    }

    /// Letters, digits, dashes and underscores, starting with a letter or a
    /// digit: nothing a shell reads as syntax, and nothing `claude attach`
    /// reads as an option (`--help`).
    public static func isSafe(id: String) -> Bool {
        guard let first = id.unicodeScalars.first, isAlphanumeric(first), id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// One line, control and format characters turned to spaces — a bidi
    /// override must not reorder what a session says it needs — cut at
    /// `maxLength`.
    static func line(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let flat = String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format ? " " : Character($0)
        })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > BackgroundJob.maxLength ? String(flat.prefix(BackgroundJob.maxLength)) : flat
    }
}
