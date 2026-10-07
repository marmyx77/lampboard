import CryptoKit
import Foundation

/// One decision pinned for a repository (§5.5, D105).
public struct PinnedDecision: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let at: Date

    public init(id: String, text: String, at: Date) {
        self.id = id
        self.text = text
        self.at = at
    }
}

public enum DecisionBoardError: Error, Equatable, Sendable {
    case empty, tooLong, duplicate, full, badRepository, noSuchDecision, unsaved

    public var sentence: String {
        switch self {
        case .empty: return "a project rule needs words"
        case .tooLong: return "a project rule is one line of at most \(DecisionBoard.maxLength) characters"
        case .duplicate: return "that project rule is already there"
        case .full: return "a repository holds at most \(DecisionBoard.maxPerRepository) project rules; remove one first"
        case .badRepository: return "not a repository name"
        case .noSuchDecision: return "no decision with that number"
        case .unsaved: return "the board could not be saved"
        }
    }
}

/// What is settled in each repository, handed to every session working in it.
///
/// Parallel sessions on one repository contradict each other because each knows
/// only its own conversation: one decides that dates are UTC, the next writes
/// local times. A decision pinned here reaches all of them — the companion mod
/// attaches the board to a session's next prompt whenever it has changed, as
/// context the model reads and the person does not see.
///
/// Small on purpose: what enters every conversation costs every conversation.
/// At most twenty decisions a repository, one line each.
///
/// Keyed by the repository's name as the hook script resolves it
/// (`GitIdentity.repo`), the same in every worktree of it. A session with no
/// repository has no board.
public struct DecisionBoard: Codable, Equatable, Sendable {
    public static let maxPerRepository = 20
    public static let maxLength = 300

    public let repositories: [String: [PinnedDecision]]

    public init(repositories: [String: [PinnedDecision]] = [:]) {
        self.repositories = repositories
    }

    public func decisions(for repository: String) -> [PinnedDecision] {
        repositories[repository] ?? []
    }

    public func pinning(_ text: String, in repository: String, id: String, at now: Date) -> Result<DecisionBoard, DecisionBoardError> {
        guard Self.isRepositoryName(repository) else { return .failure(.badRepository) }
        let line = Self.line(text)
        guard !line.isEmpty else { return .failure(.empty) }
        guard line.count <= Self.maxLength else { return .failure(.tooLong) }
        let current = decisions(for: repository)
        guard !current.contains(where: { $0.text.lowercased() == line.lowercased() }) else { return .failure(.duplicate) }
        guard current.count < Self.maxPerRepository else { return .failure(.full) }
        return .success(replacing(repository, with: current + [PinnedDecision(id: id, text: line, at: now)]))
    }

    /// Takes off the decision shown as `number` (from 1).
    public func removing(number: Int, in repository: String) -> Result<DecisionBoard, DecisionBoardError> {
        var current = decisions(for: repository)
        guard current.indices.contains(number - 1) else { return .failure(.noSuchDecision) }
        current.remove(at: number - 1)
        return .success(replacing(repository, with: current))
    }

    /// Changes when the words do and only then: what tells a session it has
    /// something new to read. The repository's name is in it too, so a session
    /// that moves to another repository with the same words is told again,
    /// under the right name. `nil` for a repository with nothing pinned.
    public func version(for repository: String) -> String? {
        let current = decisions(for: repository)
        guard !current.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(([repository] + current.map(\.text)).joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The words the model reads beside the prompt.
    public func contextBlock(for repository: String) -> String? {
        let current = decisions(for: repository)
        guard !current.isEmpty else { return nil }
        let list = current.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        return """
        Decisions pinned in LampBoard for the repository "\(repository)". Every session working in it \
        gets them. Keep to them unless the user says otherwise:
        \(list)
        """
    }

    /// What a session that was told about decisions reads once they are all
    /// gone. It names no repository: the name a session reports comes from its
    /// project (the hook script runs `git` there), and a sentence the panel
    /// signs must carry no words a project chose (a review finding).
    public static let withdrawnBlock =
        "The decisions LampBoard had pinned for this repository have all been taken off; none applies now."

    // MARK: - Internal

    private func replacing(_ repository: String, with decisions: [PinnedDecision]) -> DecisionBoard {
        var next = repositories
        next[repository] = decisions.isEmpty ? nil : decisions
        return DecisionBoard(repositories: next)
    }

    public static func isRepositoryName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
        }
    }

    /// One line: control and format characters and runs of space become one space.
    static func line(_ text: String) -> String {
        String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format ? " " : Character($0)
        })
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The board's file, `~/.lampboard/decisions.json`.
public enum DecisionBoardCodec {
    public static func encode(_ board: DecisionBoard) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(board)
    }

    public static func decode(_ data: Data) throws -> DecisionBoard {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DecisionBoard.self, from: data)
    }
}
