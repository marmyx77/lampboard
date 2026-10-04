import LampBoardCore
import Foundation

/// LampMaster's folder: what each round did, what it showed and what became of
/// it, its notebook, and the last frames it was given.
///
/// ```
/// ~/.lampboard/lampmaster/
///   rounds.jsonl       one line a round, skips included
///   suggestions.jsonl  what reached the panel, with its outcome
///   notebook.md        LampMaster's own notes between rounds
///   asks.jsonl         the questions sessions asked, the last day of them
///   frames/            the last 200 frames and answers: the test bench
/// ```
///
/// Owner-only, like the mailbox and the token: the frames and the suggestions
/// hold pieces of the user's conversations. The directory's `0700` is the guard
/// that matters; the files' `0600` is for whoever copies one out.
struct LampMasterFiles {

    static let framesKept = 200
    /// Rewrite `rounds.jsonl` down to two weeks once it passes this size: about
    /// six weeks of a round an hour.
    static let roundsRewriteBytes = 512 * 1024

    let directory: URL

    init(directory: URL = AppConfig.lampMasterDirectory) {
        self.directory = directory
    }

    var roundsURL: URL { directory.appendingPathComponent("rounds.jsonl") }
    var suggestionsURL: URL { directory.appendingPathComponent("suggestions.jsonl") }
    var notebookURL: URL { directory.appendingPathComponent("notebook.md") }
    var asksURL: URL { directory.appendingPathComponent("asks.jsonl") }
    var framesURL: URL { directory.appendingPathComponent("frames", isDirectory: true) }

    func prepare() {
        for folder in [directory, framesURL] {
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    // MARK: - Rounds

    func rounds() -> [LampMasterRound] {
        LampMasterLedger.records(read(roundsURL), as: LampMasterRound.self)
    }

    func append(_ round: LampMasterRound, now: Date) {
        guard let line = LampMasterLedger.line(round) else { return }
        prepare()
        if !FileManager.default.fileExists(atPath: roundsURL.path) {
            write("", to: roundsURL)
        }
        guard let handle = try? FileHandle(forWritingTo: roundsURL) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        let size = (try? handle.offset()) ?? 0
        try? handle.close()
        if size > Self.roundsRewriteBytes {
            let kept = rounds().filter { now.timeIntervalSince($0.at) <= LampMasterLedger.keptFor }
            write(kept.compactMap(LampMasterLedger.line).map { $0 + "\n" }.joined(), to: roundsURL)
        }
    }

    // MARK: - Suggestions

    func suggestions() -> [LampMasterShown] {
        LampMasterLedger.records(read(suggestionsURL), as: LampMasterShown.self)
    }

    /// Rewritten whole: outcomes change lines that are already there, and the
    /// file holds two weeks at most.
    func save(_ shown: [LampMasterShown]) {
        prepare()
        write(shown.compactMap(LampMasterLedger.line).map { $0 + "\n" }.joined(), to: suggestionsURL)
    }

    // MARK: - Questions

    func asks() -> [LampMasterAskLimits.Asked] {
        LampMasterLedger.records(read(asksURL), as: LampMasterAskLimits.Asked.self)
    }

    /// Kept a day: enough for the hour's limits, the reuse, and the day's
    /// ceiling, and the answers quote conversations.
    func record(_ asked: LampMasterAskLimits.Asked, now: Date) {
        prepare()
        let kept = asks().filter { now.timeIntervalSince($0.at) < 24 * 60 * 60 } + [asked]
        write(kept.compactMap(LampMasterLedger.line).map { $0 + "\n" }.joined(), to: asksURL)
    }

    /// A booked question, completed with its answer and its cost.
    func replace(_ booked: LampMasterAskLimits.Asked, with done: LampMasterAskLimits.Asked) {
        var all = asks()
        if let index = all.lastIndex(of: booked) { all[index] = done } else { all.append(done) }
        write(all.compactMap(LampMasterLedger.line).map { $0 + "\n" }.joined(), to: asksURL)
    }

    // MARK: - Notebook

    func notebook() -> String { read(notebookURL) }

    func saveNotebook(_ text: String) {
        prepare()
        write(text, to: notebookURL)
    }

    // MARK: - Frames

    /// The frame a round was given and what came back, one file a round, for
    /// replaying against a new prompt or model. Never leaves the Mac.
    func keep(frame: String, output: String, at date: Date) {
        prepare()
        let name = "\(Int(date.timeIntervalSince1970)).jsonl"
        write(frame + "\n" + output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
              to: framesURL.appendingPathComponent(name))
        // By the number in the name, not its spelling: a string sort is
        // chronological only while every stamp has the same number of digits.
        let stamp = { (name: String) in Int(name.dropLast(".jsonl".count)) ?? 0 }
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: framesURL.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .sorted { stamp($0) < stamp($1) }
        for old in all.dropLast(Self.framesKept) {
            try? FileManager.default.removeItem(at: framesURL.appendingPathComponent(old))
        }
    }

    // MARK: - Internals

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Born `0600` and renamed into place, as `TokenStore` writes the token:
    /// written first and tightened after, the file would be readable for a
    /// moment, and only the folder's `0700` would be covering for it.
    private func write(_ text: String, to url: URL) {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).new")
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(
            atPath: staging.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]
        ) else { return }
        if rename(staging.path, url.path) != 0 { try? FileManager.default.removeItem(at: staging) }
    }
}
