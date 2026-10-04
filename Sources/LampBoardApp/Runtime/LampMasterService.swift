import LampBoardCore
import Foundation

/// LampMaster's round, from the panel's rows to the suggestions on screen.
///
/// Every decision is in Core — what enters the frame, when a round is skipped,
/// what the validator lets through, what settles a suggestion. This class reads
/// the disk, runs `claude`, and keeps the results where the panel and the
/// server can see them.
@MainActor
final class LampMasterService: ObservableObject {

    /// What the panel and `GET /lampmaster` show.
    struct Snapshot: Encodable, Equatable {
        var enabled = false
        var running = false
        var tokensToday = 0
        /// Recorded today, skips included.
        var roundsToday = 0
        var lastRound: LampMasterRound?
        var open: [LampMasterShown] = []
    }

    @Published private(set) var snapshot = Snapshot()

    /// The timer's tick. A round is due once an interval has passed; the tick
    /// only has to notice within a few minutes, and each tick that finds one
    /// due reads the transcripts.
    static let tick: TimeInterval = 5 * 60

    private let preferences: Preferences
    private let rows: @MainActor () -> [SessionState]
    private let files: LampMasterFiles
    private let cards: LampMasterCards
    private let box = LampMasterBox()
    private var timer: Timer?

    init(
        preferences: Preferences, rows: @escaping @MainActor () -> [SessionState],
        files: LampMasterFiles = LampMasterFiles(), cards: LampMasterCards = LampMasterCards()
    ) {
        self.preferences = preferences
        self.rows = rows
        self.files = files
        self.cards = cards
    }

    /// The state for the server's queue, encoded.
    nonisolated var encodedState: Data { box.current() }

    func start() {
        publish(running: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.request(.timer) }
        }
    }

    /// Also ends a round's `claude` still running: quitting must not leave
    /// it spending the allowance for two more minutes with nobody to record it.
    func stop() {
        timer?.invalidate()
        timer = nil
        LampMasterRunner.running.stop()
    }

    /// Asks for a round. One at a time: a request while one runs is dropped,
    /// because the running one already answers it, and `false` says so.
    @discardableResult
    func request(_ trigger: LampMasterSchedule.Trigger) -> Bool {
        guard !snapshot.running else { return false }
        // A disabled timer reads nothing: the cheapest round is the one never
        // prepared.
        if trigger == .timer, !preferences.lampMasterEnabled { return true }
        // Published, not only set: the server reads the box, and a round in
        // flight that `GET /lampmaster` reported as idle was a review finding.
        publish(running: true)
        Task { await round(trigger) }
        return true
    }

    /// The switch, from Settings. Published at once: the panel's line comes and
    /// goes with it. The first round follows within a tick, since none has run.
    func setEnabled(_ enabled: Bool) {
        preferences.lampMasterEnabled = enabled
        if !enabled { LampMasterRunner.running.stop() }
        publish(running: enabled && snapshot.running)
    }

    /// The user's reaction to a suggestion on screen.
    func react(to id: String, with outcome: LampMasterShown.Outcome) {
        let shown = files.suggestions()
        if outcome == .muted, let kind = shown.first(where: { $0.id == id })?.suggestion.kind {
            preferences.lampMasterMuted.insert(kind)
        }
        files.save(LampMasterLedger.resolve(shown, id: id, outcome: outcome, now: Date()))
        publish(running: snapshot.running)
    }

    // MARK: - The round

    private func round(_ trigger: LampMasterSchedule.Trigger) async {
        let now = Date()
        let rounds = files.rounds()
        let last = LampMasterLedger.lastRun(rounds)
        if trigger == .timer, let at = last?.at, now.timeIntervalSince(at) < LampMasterSchedule.clamp(preferences.lampMasterInterval) {
            return publish(running: false)
        }

        let found = await cards.sessions(live: rows().compactMap(Self.live), now: now)
        let muted = preferences.lampMasterMuted
        var shown = files.suggestions()
        let frame = LampMasterFrameBuilder.build(
            sessions: found, now: now, recent: LampMasterLedger.recent(shown, now: now),
            muted: muted.map(\.rawValue), notebook: files.notebook()
        )
        let ids = Set(frame.sessions.map(\.id))
        shown = LampMasterLedger.settle(shown, present: ids, now: now)
        files.save(shown)

        let digest = LampMasterSchedule.digest(frame)
        let decision = LampMasterSchedule.decide(
            trigger: trigger, enabled: preferences.lampMasterEnabled, interval: preferences.lampMasterInterval,
            lastRun: last?.at, lastDigest: last?.digest, digest: digest, sessionCount: frame.sessions.count,
            tokensToday: LampMasterLedger.tokens(on: now, in: rounds), now: now
        )
        switch decision {
        case .wait:
            return publish(running: false)
        case .skip(let reason):
            if Self.records(skip: reason, trigger: trigger, rounds: rounds, interval: preferences.lampMasterInterval, now: now) {
                files.append(LampMasterRound(at: now, trigger: trigger, outcome: .skipped, skip: reason,
                                             sessions: frame.sessions.count, digest: digest), now: now)
            }
            return publish(running: false)
        case .run:
            break
        }

        let text = frame.json()
        let model = preferences.lampMasterModel
        let system = LampMasterPrompt.system(language: Self.language)
        let timeout = preferences.lampMasterTimeout
        let directory = files.directory
        files.prepare()
        let (run, output) = await Task.detached {
            LampMasterRunner.run(message: LampMasterPrompt.message(frame: text), model: model, system: system,
                                 directory: directory, timeout: timeout)
        }.value

        var verdict = LampMasterValidator.Verdict(shown: [], rejected: [])
        if let advice = run.advice {
            verdict = LampMasterValidator.screen(
                advice, frame: text, ids: ids, shownAt: LampMasterLedger.shownAt(shown), muted: muted, now: now
            )
            if let notebook = advice.notebook { files.saveNotebook(String(notebook.prefix(1_500))) }
            files.save(shown + LampMasterLedger.entries(for: verdict.shown, at: now))
        }
        files.keep(frame: text, output: output, at: now)
        files.append(LampMasterRound(
            at: now, trigger: trigger, outcome: run.failure == nil ? .ran : .failed, failure: run.failure,
            model: model, seconds: run.seconds, tokens: run.tokens, costUSD: run.costUSD,
            sessions: frame.sessions.count, frameTokens: frame.estimatedTokens,
            proposed: run.advice?.suggestions.count ?? 0, rejected: LampMasterLedger.rejections(verdict),
            shown: verdict.shown.count, digest: digest
        ), now: now)
        publish(running: false)
    }

    /// A skip asked for is recorded, except a second "too soon" in a row: a
    /// loop of requests must not grow the file either. The timer's skips only
    /// once an interval, or a quiet day would write a line every five minutes,
    /// and "off" from the timer never: switched off is not a round.
    static func records(
        skip: LampMasterSchedule.Skip, trigger: LampMasterSchedule.Trigger, rounds: [LampMasterRound],
        interval: TimeInterval, now: Date
    ) -> Bool {
        guard trigger == .timer else { return skip != .tooSoon || rounds.last?.skip != .tooSoon }
        guard skip != .off, let latest = rounds.last else { return skip != .off }
        return now.timeIntervalSince(latest.at) >= LampMasterSchedule.clamp(interval)
    }

    private func publish(running: Bool) {
        let shown = files.suggestions()
        let rounds = files.rounds()
        let now = Date()
        let next = Snapshot(
            enabled: preferences.lampMasterEnabled, running: running,
            tokensToday: LampMasterLedger.tokens(on: now, in: rounds),
            roundsToday: rounds.filter { Calendar.current.isDate($0.at, inSameDayAs: now) }.count,
            lastRound: rounds.last, open: LampMasterLedger.open(shown)
        )
        if next != snapshot { snapshot = next }
        box.replace(with: LampMasterLedger.line(next).map { Data($0.utf8) } ?? Data("{}".utf8))
    }

    // MARK: - From the panel's rows

    /// A row of this Mac's Claude Code, as the cards need it. Rows on other
    /// machines wait for the nodes' stage (D4), and Codex for its own reader.
    static func live(_ row: SessionState) -> LampMasterCards.Live? {
        guard !row.workspace.isRemote, row.harness == .claudeCode else { return nil }
        let liveness: LampMasterSession.Liveness
        switch row.status {
        case .working: liveness = .working
        case .awaiting: liveness = .asking
        // `waiting` is a turn over with background work running: a dev server
        // left on for a day is not a turn stuck for a day.
        case .waiting, .idle, .ready, .failed: liveness = .idle
        }
        return LampMasterCards.Live(
            sessionId: row.id, transcriptPath: row.transcriptPath, cwd: row.workspace.path,
            liveness: liveness, surface: "\(row.origin)", agent: "claude-code",
            repository: row.git?.repo, branch: row.git?.branch, contextWindow: row.context?.window
        )
    }

    /// The language the suggestions are written in: the Mac's first, by its
    /// English name, because the prompt is in English.
    static var language: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}

/// Runs the round's `claude`.
enum LampMasterRunner {

    /// Where `claude` is. A GUI application's `PATH` is four system folders,
    /// none of them where anybody installs it, so the usual places come first.
    /// Under `LAMPBOARD_HOME` only the fake home's own is looked at: a test that
    /// forgot its fake `claude` must fail, not spend the real one.
    static func executable() -> String? {
        let own = AppConfig.homeDirectory.appendingPathComponent(".local/bin/claude").path
        let candidates = AppConfig.isUsingHomeOverride ? [own] : [own, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `claude` of the round in flight, if any.
    static let running = RunningProcess()

    /// The run, and what `claude` printed, kept with the frame.
    static func run(
        message: String, model: String, system: String, directory: URL, timeout: TimeInterval
    ) -> (LampMasterRun, String) {
        guard let tool = executable() else { return (.failed(.notLaunched), "") }
        let started = Date()
        do {
            let result = try Command.run(
                tool, LampMasterCommand.arguments(model: model, system: system), deadline: timeout,
                capturingStandardError: false, input: Data(message.utf8), directory: directory,
                launched: { running.hold($0) }
            )
            running.release()
            let run = LampMasterRun.read(Data(result.output.utf8))
            let seconds = run.seconds ?? Date().timeIntervalSince(started)
            return (LampMasterRun(advice: run.advice, failure: run.failure, inputTokens: run.inputTokens,
                                  outputTokens: run.outputTokens, costUSD: run.costUSD, seconds: seconds), result.output)
        } catch Command.Failure.timedOut {
            running.release()
            return (.failed(.timedOut, seconds: Date().timeIntervalSince(started)), "")
        } catch {
            running.release()
            return (.failed(.notLaunched), "")
        }
    }
}

/// The process id of a running tool, held only while it runs: a pid kept
/// after its process ended could name somebody else's by the time it is used.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?

    func hold(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        self.pid = pid
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        pid = nil
    }

    /// `SIGTERM`, the way `Command` asks first.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let pid { kill(pid, SIGTERM) }
        pid = nil
    }
}

/// LampMaster's state for the server's queue, the way `SnapshotBox` holds the
/// rows: deposited when it changes, collected when asked, nobody waiting.
final class LampMasterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data("{}".utf8)

    func replace(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored = data
    }

    func current() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
