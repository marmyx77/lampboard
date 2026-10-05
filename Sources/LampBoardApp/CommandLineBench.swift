import Foundation
import LampBoardCore

/// `lampboard lampmaster bench` (D102): LampMaster's last saved rounds replayed
/// with the model chosen — or another, `--model` — through the round's own
/// isolated `claude`, both answers screened by the round's validator, and the
/// suggestions compared, by key, with the old ones and with what the person did
/// with them. Spends one round's tokens per frame; never runs by itself.
extension CommandLineInterface {

    static func runBench(model: String?, last: Int) -> Int32 {
        let files = LampMasterFiles()
        let saved = files.savedRounds(last: last)
        guard !saved.isEmpty else {
            print("No saved round yet: LampMaster keeps the frames of its rounds in \(files.framesURL.path).")
            return 0
        }
        let preferences = Preferences()
        let chosen = model.flatMap { LampMasterCommand.models.contains($0) ? $0 : nil } ?? preferences.lampMasterModel
        if let model, model != chosen { print("Unknown model \(model): using \(chosen).") }
        // What the person did with each suggestion, by its key; the last word wins.
        let outcomes = Dictionary(files.suggestions().compactMap { shown in shown.outcome.map { (shown.suggestion.key, $0) } },
                                  uniquingKeysWith: { _, last in last })
        print("Replaying \(saved.count) round\(saved.count == 1 ? "" : "s") with \(chosen): one round's tokens each.")
        var rows: [(at: Date, comparison: LampMasterBench.Comparison)] = []
        for round in saved {
            let ids = frameIds(round.frame)
            let old = screened(LampMasterRun.read(Data(round.output.utf8)).advice, frame: round.frame, ids: ids, at: round.at)
            let (run, _) = LampMasterRunner.run(
                message: LampMasterPrompt.message(frame: round.frame), model: chosen,
                system: LampMasterPrompt.system(language: LampMasterService.language), schema: LampMasterPrompt.schema,
                directory: files.directory, timeout: preferences.lampMasterTimeout
            )
            if let failure = run.failure { print("A replay failed: \(LampMasterLine.reason(failure)).") }
            let new = screened(run.advice, frame: round.frame, ids: ids, at: round.at)
            rows.append((round.at, LampMasterBench.compare(old: old, new: new, outcomes: outcomes)))
        }
        print(LampMasterBench.report(rows, model: chosen))
        return 0
    }

    /// The suggestions the round would have shown: the same validator, nothing
    /// muted and nothing remembered, so two answers are judged alike.
    private static func screened(_ advice: LampMasterAdvice?, frame: String, ids: Set<String>, at: Date) -> [LampMasterAdvice.Suggestion] {
        guard let advice else { return [] }
        return LampMasterValidator.screen(advice, frame: frame, ids: ids, shownAt: [:], muted: [], now: at).shown
    }

    private static func frameIds(_ frame: String) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else { return [] }
        return Set(sessions.compactMap { $0["id"] as? String })
    }
}
