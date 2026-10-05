import LampBoardCore
import Foundation

/// The decision board on disk, `~/.lampboard/decisions.json` (D105).
///
/// Read once at launch, written whole on every change through a file created
/// 0600 and renamed into place: the panel is its only writer, the command line
/// and the mod reach it through the server. A file that cannot be read is an
/// empty board, said in the log, and is set aside as `decisions.json.unreadable`
/// rather than overwritten by the next pin.
final class DecisionBoardService: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var board: DecisionBoard

    init(url: URL = AppConfig.decisionBoardFile) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            if let board = try? DecisionBoardCodec.decode(data) {
                self.board = board
            } else {
                // Set aside, not overwritten by the next pin: what was in it is
                // the person's, and may be worth reading.
                let aside = url.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
                Diagnostics.log("decision board: \(url.lastPathComponent) unreadable, set aside as \(aside.lastPathComponent)")
                self.board = DecisionBoard()
            }
        } else {
            self.board = DecisionBoard()
        }
    }

    var current: DecisionBoard { lock.withLock { board } }

    /// Applies a change and saves it; the board as it now is, or why not.
    func apply(_ change: DecisionBoardExchange.Change, now: Date = Date()) -> Result<DecisionBoard, DecisionBoardError> {
        lock.withLock {
            let result: Result<DecisionBoard, DecisionBoardError>
            switch change {
            case .pin(let repository, let text):
                result = board.pinning(text, in: repository, id: String(UUID().uuidString.prefix(8)).lowercased(), at: now)
            case .remove(let repository, let number):
                result = board.removing(number: number, in: repository)
            }
            if case .success(let next) = result {
                guard save(next) else { return .failure(.unsaved) }
                board = next
            }
            return result
        }
    }

    /// `/decisions`: a change, or the listing when there is none.
    func handle(_ body: Data?) -> (Int, String) {
        if let body {
            guard let change = DecisionBoardExchange.change(body) else { return (400, "not a change to the board") }
            if case .failure(let error) = apply(change) { return (400, error.sentence) }
        }
        guard let data = try? DecisionBoardCodec.encode(current) else { return (500, "the board could not be written out") }
        return (200, String(decoding: data, as: UTF8.self))
    }

    private func save(_ next: DecisionBoard) -> Bool {
        guard let data = try? DecisionBoardCodec.encode(next) else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".\(url.lastPathComponent).new")
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return false }
        guard rename(staging.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        return true
    }
}
