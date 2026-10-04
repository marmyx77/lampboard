import Foundation

/// How full a session's context is, and how much that figure can be trusted.
///
/// WHY THE CONFIDENCE IS PART OF THE VALUE
/// Only `assistant` records carry a token count, so what can be read is the
/// context as it stood at the **last reply**. Anything loaded since — a pasted
/// file, a tool result, a resumed history — is invisible. Measured across 171
/// compaction boundaries, the real figure was a median of 1.00× the last reading
/// and a maximum of **17.67×**: one session would have displayed 56,555 while
/// holding close to a million.
///
/// A percentage that is sometimes seventeen times too small is not a percentage,
/// it is a trap — somebody would start a large task on the strength of it. So
/// the reading carries what happened after it was taken, and the panel says
/// `62%`, `≥62%` or `—` accordingly. The `≥` and the dash are the feature; the
/// number on its own is the part that would lie.
public struct ContextReading: Sendable, Equatable {

    /// What can be claimed about the number.
    public enum Confidence: String, Sendable, Equatable, Codable {
        /// Nothing has been added since the reply this was read from.
        case exact
        /// The harness stated its own window in the same record as the count.
        ///
        /// Stronger than `exact`, and kept apart from it on purpose. `exact`
        /// means we measured the denominator and believe it; `declared` means we
        /// did not have to. Codex writes `model_context_window` beside the token
        /// count, so nothing about that percentage rests on a table of ours that
        /// a vendor could invalidate without telling anybody.
        case declared
        /// The session counted it itself and the companion mod passed it on:
        /// the figure Claude Code's own status line shows. The strongest of all,
        /// so a transcript reading never replaces it (`StateReducer`, D65).
        case reported
        /// Something was loaded afterwards: the true figure is higher.
        case floor
        /// A compaction or a refused prompt sits after it. The number is known
        /// to be wrong, and is not shown at all.
        case unknown
    }

    public let tokens: Int
    /// The model **of the same record** the tokens came from. A session
    /// interleaves models — twenty-eight switches in one real transcript — so
    /// taking it from anywhere else describes a different turn.
    public let model: String
    /// `nil` when the model is not in the table, which means no percentage.
    public let window: Int?
    public let confidence: Confidence
    /// The timestamp of the reply, not of the read: the panel says how old this is.
    public let at: Date?

    public init(tokens: Int, model: String, window: Int?, confidence: Confidence, at: Date?) {
        self.tokens = tokens
        self.model = model
        self.window = window
        self.confidence = confidence
        self.at = at
    }

    /// `nil` when there is no denominator, or when the number is known to be wrong.
    ///
    /// THE DENOMINATOR IS THE WHOLE WINDOW, AND THAT WAS MEASURED
    /// Claude Code compacts before the window is full — its own indicator counts
    /// down to `window − min(maxOutputTokens, 20 000) − 13 000`, read out of the
    /// binary — but it counts *its own* token estimate, which is not this sum and
    /// can differ from it by anything between 0.3% and sixty-fold. Borrowing that
    /// threshold means dividing our number by their denominator.
    ///
    /// So the question was asked of the transcripts instead: at what value of
    /// **this** sum does a session actually get compacted? Every auto-compaction
    /// in 18,622 files — 236 of them — says the same thing: never above the
    /// window, and up to 99.91% of it on a 1M model, 99.99% on a 200k one. The
    /// window is the ceiling. `Scripts/measure-compaction.py` re-runs it.
    ///
    /// Not clamped on purpose. A figure above 100% would mean the window in the
    /// table moved, and that is worth seeing rather than hiding under a `min`.
    public var percent: Int? {
        guard let window, window > 0, confidence != .unknown else { return nil }
        return Int((Double(tokens) / Double(window) * 100).rounded())
    }

    /// How much of the ring is drawn, `0...1`, or `nil` when nothing may be drawn.
    ///
    /// Clamped where `percent` is not, and for the opposite reason: an arc past
    /// the end of the circle draws a second lap over the first and reads as
    /// *emptier*, which is the one direction this must never fail in.
    public var fraction: Double? {
        guard let window, window > 0, confidence != .unknown else { return nil }
        return min(1, Double(tokens) / Double(window))
    }

    /// The letter inside the ring: the family of the model that produced the reply.
    public var modelInitial: String { Self.initial(of: model) }

    /// `O`, `S`, `H`, `F`, `M` — or `n` for a model nobody here has heard of.
    ///
    /// Matched on the family word wherever it appears, not on position: the ids
    /// are not all shaped the same, and `claude-3-5-haiku` carries its numbers in
    /// the middle. `n` is a statement — *this is a model I do not know* — and it
    /// is a different fact from an empty ring, which means nothing was read.
    public static func initial(of model: String) -> String {
        for (family, letter) in families where model.contains(family) {
            return letter
        }
        return "n"
    }

    private static let families: [(String, String)] = [
        ("opus", "O"), ("sonnet", "S"), ("haiku", "H"), ("fable", "F"), ("mythos", "M"),
        // Codex reports `gpt-5.6-sol` and its kin. `G` and not `5`: a digit in
        // that cell reads as a version number next to a column of letters, and
        // the cell has one job, which is to be told apart at a glance.
        ("gpt", "G"), ("codex", "G"), ("o3", "G"), ("o4", "G"),
    ]

    /// What a row shows. Never empty: a blank cell reads as "there is room",
    /// which is exactly what would make somebody start a large task in a session
    /// that has none.
    public var label: String {
        guard let percent else { return "—" }
        return confidence == .floor ? "≥\(percent)%" : "\(percent)%"
    }

    /// The full sentence, for the tooltip, where the whole truth fits.
    public var explanation: String {
        guard let window, confidence != .unknown else {
            return confidence == .unknown
                ? "context unknown: the session was compacted since the last reading"
                : "context \(tokens.formatted()) tokens (\(model), no window recorded)"
        }
        let prefix = confidence == .floor ? "at least " : ""
        return "context \(label): \(prefix)\(tokens.formatted()) of \(window.formatted()) (\(model))"
    }
}

/// The denominator, per model.
///
/// Not discoverable from a transcript: it records `claude-opus-5` and says
/// nothing about the window, and a session started with `--model sonnet` — no
/// suffix — resolves to a million. The window is a property of the model, and
/// these numbers are Claude Code's own, read out of its model registry.
///
/// `Contracts/required-fields.json` carries the same table and
/// `Scripts/check-contract.sh` re-reads the binary on every run, so a window
/// that moves in a release is reported instead of silently dividing wrong.
public enum ContextWindows {

    public static let byModel: [String: Int] = [
        "claude-opus-5": 1_000_000,
        "claude-sonnet-5": 1_000_000,
        "claude-fable-5": 1_000_000,
        "claude-mythos-5": 1_000_000,
        "claude-opus-4-7": 1_000_000,
        "claude-opus-4-8": 1_000_000,
        "claude-opus-4-0": 200_000,
        "claude-opus-4-1": 200_000,
        "claude-opus-4-5": 200_000,
        "claude-opus-4-6": 200_000,
        "claude-sonnet-4-0": 200_000,
        "claude-sonnet-4-5": 200_000,
        "claude-sonnet-4-6": 200_000,
        "claude-haiku-4-5": 200_000,
        "claude-3-5-haiku": 200_000,
        "claude-3-7-sonnet": 200_000,
    ]

    /// The window, or `nil` — which means no percentage rather than a guess.
    ///
    /// A transcript writes the model with its release date attached
    /// (`claude-sonnet-4-5-20250929`) about as often as without, so the suffix
    /// comes off before the lookup. Only a trailing group of exactly eight
    /// digits: `claude-3-5-haiku` must keep its own numbers.
    ///
    /// A POINT RELEASE INHERITS, AND THE ALTERNATIVE WAS MEASURED
    /// `claude-fable-5-1` shipped while this table said `claude-fable-5`, and
    /// nothing here knew it: the installed Claude Code 2.1.251 registry does not
    /// carry that id either, so the check that holds this table against the
    /// binary stayed green while every session on that model lost its arc. The
    /// failure was silent in the worst way — the ring still drew, so it read as
    /// *nothing has been measured* rather than as *this model is unknown*.
    ///
    /// So a trailing minor group falls back to its parent. `claude-fable-5-1`
    /// asks `claude-fable-5` and gets a million. That is an inheritance and not
    /// an invention: it is the same model family and generation, and the number
    /// it borrows was read out of the registry like every other one here.
    ///
    /// It can still be wrong, on the day a point release moves its own window.
    /// That is why it is not silent either: `inheritedParent(of:)` names what was
    /// borrowed, and `Scripts/check-contract.sh` reads the model ids out of real
    /// transcripts and reports every one that only resolved this way.
    public static func window(for model: String) -> Int? {
        let key = stripped(model)
        if let exact = byModel[key] { return exact }
        if let parent = parentOf(key) { return byModel[parent] }
        return nil
    }

    /// The parent a model borrowed its window from, or `nil` when it needed none.
    public static func inheritedParent(of model: String) -> String? {
        let key = stripped(model)
        guard byModel[key] == nil, let parent = parentOf(key), byModel[parent] != nil else {
            return nil
        }
        return parent
    }

    /// `claude-fable-5-1` → `claude-fable-5`. Only a trailing group of one or two
    /// digits, so `claude-3-5-haiku` — whose numbers are in the middle — and
    /// `claude-sonnet-4-5`, whose `5` is its own generation, are reached the
    /// ordinary way and never come through here.
    private static func parentOf(_ key: String) -> String? {
        let parts = key.split(separator: "-")
        guard parts.count > 2, let last = parts.last,
              last.count <= 2, last.allSatisfy(\.isNumber) else { return nil }
        return parts.dropLast().joined(separator: "-")
    }

    public static func stripped(_ model: String) -> String {
        let parts = model.split(separator: "-")
        guard let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) else {
            return model
        }
        return parts.dropLast().joined(separator: "-")
    }
}
