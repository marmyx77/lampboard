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
    /// only has to notice within a few minutes. A tick between two rounds
    /// looks for a quick one (D72), since a session that stopped moving sends
    /// no event to be noticed by.
    static let tick: TimeInterval = 5 * 60
    /// The most often an event may look for a quick round: a turn that fails
    /// three tools in a second is one look.
    static let nudgeSpacing: TimeInterval = 60
    /// The hook events after which a session may newly repeat a failure: the
    /// end of a turn, and a tool that failed. The mod's end of a tool is the
    /// third door, for sessions whose failures the hooks do not report.
    static let nudgedBy: Set<HookEventKind> = [.stop, .stopFailure, .postToolUseFailure]

    let preferences: Preferences
    let rows: @MainActor () -> [SessionState]
    let files: LampMasterFiles
    let cards: LampMasterCards
    private let box = LampMasterBox()
    /// What was said in earlier conversations, for `who_knows` (D89): the
    /// search index, set by whoever owns it.
    var remember: (@Sendable (String) -> [LampMasterLookup.Remembered])?
    /// The same, wider: a question from the panel searches word by word and
    /// keeps what two words agree on, which a top six per word rarely shares.
    var rememberMany: (@Sendable (String) -> [LampMasterLookup.Remembered])?
    /// The search index's conversations for a failure's words, with what was
    /// said around them: the round's precedents (D3).
    var precedentsSearch: (@Sendable (String) -> [LampMasterPrecedents.Hit])?
    /// The allowance strip's reports, this Mac's first (D4): the frame's quota,
    /// and the rule that the round gives way when its own account is tight.
    var allowance: () -> [AllowanceReport] = { [] }

    /// Questions from sessions being answered now (`LampMasterQuestions`).
    var questionsRunning = 0
    /// The conversation in LampMaster's Plancia (D118): kept while the panel
    /// runs, so a tab or the Plancia closing does not lose it.
    @Published var conversation: [LampMasterAsk.Exchange] = []
    /// The trial's answer to any question (D120): a trial never runs a model.
    var scripted: ((String) -> String)?
    /// A question of that conversation being answered, and why the last failed.
    @Published var conversing: String?
    @Published var conversationError: String?
    /// The port this panel listens on, which the MCP server's entry must name.
    var port = AppConfig.listenPort
    private var timer: Timer?
    private var lastNudge: Date?
    /// A quick look reading the frame, before it knows whether to run.
    private var looking = false

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
        guard !snapshot.running, !looking else { return false }
        // A disabled timer reads nothing: the cheapest round is the one never
        // prepared.
        if trigger == .timer || trigger == .quick, !preferences.lampMasterEnabled { return true }
        // Published, not only set: the server reads the box, and a round in
        // flight that `GET /lampmaster` reported as idle was a review finding.
        // A quick look is not a round until the frame says one is due: shown as
        // running, every turn's end would flicker the line (a review finding).
        if trigger == .quick {
            looking = true
        } else {
            publish(running: true)
        }
        Task {
            await round(trigger)
            looking = false
        }
        return true
    }

    /// A turn ended or a tool failed somewhere: a quick round may be due (D72).
    /// The frame decides whether it is; this only keeps the looks to one a minute.
    func nudge(now: Date = Date()) {
        guard preferences.lampMasterEnabled else { return }
        if let lastNudge, now.timeIntervalSince(lastNudge) < Self.nudgeSpacing { return }
        // Spent only on a look that starts: an event during a round would
        // otherwise hold the next one back for a minute.
        if request(.quick) { lastNudge = now }
    }

    /// The switch, from Settings. Published at once: the panel's line comes and
    /// goes with it. The first round follows within a tick, since none has run.
    func setEnabled(_ enabled: Bool) {
        preferences.lampMasterEnabled = enabled
        if !enabled { LampMasterRunner.running.stop() }
        publish(running: enabled && snapshot.running)
    }

    /// What the window shows beside the cards (D5), read from the files when asked.
    func sheets(now: Date = Date()) -> (today: [LampMasterSheets.TodayLine], frame: LampMasterSheets.FrameSheet?,
                                        cost: LampMasterSheets.CostSheet) {
        let shown = files.suggestions()
        return (LampMasterSheets.today(shown, now: now), LampMasterSheets.frame(files.latestFrame()),
                LampMasterSheets.cost(rounds: files.rounds(), shown: shown, muted: preferences.lampMasterMuted,
                                      autoMuted: preferences.lampMasterAutoMuted, now: now))
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

    private func round(_ asked: LampMasterSchedule.Trigger) async {
        let now = Date()
        let rounds = files.rounds()
        let last = LampMasterLedger.lastRun(rounds)
        var trigger = asked
        if trigger == .timer, let at = last?.at, now.timeIntervalSince(at) < LampMasterSchedule.clamp(preferences.lampMasterInterval) {
            trigger = .quick
        }

        var found = await cards.sessions(live: rows().compactMap(Self.live), now: now)
        // The nodes' sessions too, one ssh per node, only while LampMaster is on (D4).
        if preferences.lampMasterEnabled {
            found += await nodeSessions(rows().compactMap(Self.remote))
        }
        var shown = files.suggestions()
        // A kind the person keeps passing over switches itself off (D5), and says why.
        for verdict in LampMasterAutoMute.verdicts(shown, muted: preferences.lampMasterMuted,
                                                    since: preferences.lampMasterAskedBack, now: now) {
            preferences.lampMasterMuted.insert(verdict.kind)
            preferences.lampMasterAutoMuted[verdict.kind] = verdict.reason
            Diagnostics.log("lampmaster: \(verdict.kind.rawValue) switched itself off, \(verdict.reason)")
        }
        let muted = preferences.lampMasterMuted
        let reports = allowance()
        var frame = LampMasterFrameBuilder.build(
            sessions: found, now: now, quota: LampMasterQuota.frame(reports, now: now),
            recent: LampMasterLedger.recent(shown, now: now),
            muted: muted.map(\.rawValue), notebook: files.notebook()
        )
        let ids = Set(frame.sessions.map(\.id))
        shown = LampMasterLedger.settle(shown, present: ids, now: now)
        files.save(shown)

        // Not due is not a skip: nothing is written, or every turn's end would.
        // A round from before quick rounds kept no pairs: what is urgent now
        // counts as seen by it, or the first look after an update would run
        // for sessions the hourly round already knew (a review finding).
        let urgent = LampMasterQuick.urgent(in: frame)
        let seen = last.map { $0.urgent.map(Set.init) ?? urgent } ?? []
        if trigger == .quick, !LampMasterQuick.due(
            urgent: urgent, seen: seen, lastRun: last?.at,
            quickToday: LampMasterQuick.count(on: now, in: rounds), now: now
        ) {
            return publish(running: false)
        }

        let digest = LampMasterSchedule.digest(frame)
        let decision = LampMasterSchedule.decide(
            trigger: trigger, enabled: preferences.lampMasterEnabled, interval: preferences.lampMasterInterval,
            lastRun: last?.at, lastDigest: last?.digest, digest: digest, sessionCount: frame.sessions.count,
            tokensToday: tokensToday(rounds: rounds, now: now),
            quotaTight: LampMasterQuota.tight(reports, now: now), now: now
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
            if !snapshot.running { publish(running: true) }
        }

        // Searched only for a round that runs, and only for the sessions the
        // frame kept, off the main actor: candidates, not recollections (D3).
        // The digest above is the sessions': a precedent alone is no reason to run.
        if let search = precedentsSearch {
            let kept = Set(frame.sessions.map(\.id))
            let precedents = await Task.detached(priority: .utility) {
                LampMasterPrecedents.frame(for: found.filter { kept.contains($0.shortId) }, now: now, search: search)
            }.value
            LampMasterFrameBuilder.add(precedents, to: &frame)
        }
        let text = frame.json()
        let model = trigger == .quick ? LampMasterQuick.model : preferences.lampMasterModel
        let system = LampMasterPrompt.system(language: Self.language)
        let timeout = preferences.lampMasterTimeout
        let directory = files.directory
        files.prepare()
        let (run, output) = await Task.detached {
            LampMasterRunner.run(message: LampMasterPrompt.message(frame: text), model: model, system: system,
                                 schema: LampMasterPrompt.schema, directory: directory, timeout: timeout)
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
            shown: verdict.shown.count, digest: digest, urgent: urgent.sorted()
        ), now: now)
        publish(running: false)
    }

    /// A skip asked for is recorded, except a second "too soon" in a row: a
    /// loop of requests must not grow the file either. The timer's skips only
    /// once an interval, or a quiet day would write a line every five minutes,
    /// and "off" from the timer never: switched off is not a round. A quick
    /// round's skips are the timer's: an event, not a person, asked for it.
    static func records(
        skip: LampMasterSchedule.Skip, trigger: LampMasterSchedule.Trigger, rounds: [LampMasterRound],
        interval: TimeInterval, now: Date
    ) -> Bool {
        guard trigger == .timer || trigger == .quick else { return skip != .tooSoon || rounds.last?.skip != .tooSoon }
        guard skip != .off, let latest = rounds.last else { return skip != .off }
        return now.timeIntervalSince(latest.at) >= LampMasterSchedule.clamp(interval)
    }

    /// The day's spending: the rounds and the questions sessions asked share one
    /// ceiling, because they share one allowance.
    func tokensToday(rounds: [LampMasterRound], now: Date) -> Int {
        LampMasterLedger.tokens(on: now, in: rounds)
            + files.asks().filter { Calendar.current.isDate($0.at, inSameDayAs: now) }.reduce(0) { $0 + ($1.tokens ?? 0) }
    }

    func publish(running: Bool) {
        let shown = files.suggestions()
        let rounds = files.rounds()
        let now = Date()
        let next = Snapshot(
            enabled: preferences.lampMasterEnabled, running: running,
            tokensToday: tokensToday(rounds: rounds, now: now),
            roundsToday: rounds.filter { Calendar.current.isDate($0.at, inSameDayAs: now) }.count,
            lastRound: rounds.last, open: LampMasterLedger.open(shown)
        )
        if next != snapshot { snapshot = next }
        box.replace(with: LampMasterLedger.line(next).map { Data($0.utf8) } ?? Data("{}".utf8))
    }

    // MARK: - From the panel's rows

    /// A row of this Mac's Claude Code, as the cards need it. Codex waits for
    /// its own reader.
    static func live(_ row: SessionState) -> LampMasterCards.Live? {
        guard !row.workspace.isRemote, row.harness == .claudeCode else { return nil }
        return facts(row)
    }

    /// A row of Claude Code on another machine, with the path its hook gave (D4).
    static func remote(_ row: SessionState) -> LampMasterCards.Remote? {
        guard let host = row.workspace.host, RemoteHostList.isUsable(host), row.harness == .claudeCode,
              row.transcriptPath != nil, let facts = facts(row) else { return nil }
        return LampMasterCards.Remote(host: host, live: facts)
    }

    /// The nodes' transcripts read over ssh, each node once and all at once, off
    /// the main actor; a node that does not answer within its time is left as it was.
    private func nodeSessions(_ remote: [LampMasterCards.Remote]) async -> [LampMasterSession] {
        guard !remote.isEmpty else { return [] }
        let asks = await cards.remoteAsks(remote)
        let tail = UInt64(AppConfig.transcriptInitialWindow)
        let reads = await withTaskGroup(of: (String, [RemoteTranscriptScript.Read]).self) { group in
            for (host, list) in asks {
                group.addTask {
                    // ssh waits on its own thread, never on one of the shared pool's.
                    await withCheckedContinuation { done in
                        DispatchQueue.global(qos: .utility).async {
                            let script = RemoteTranscriptScript.script(list, tail: tail)
                            let cap = RemoteTranscriptScript.maxBytes * 2 * list.count + 65_536
                            switch RemoteCommand.runPython(on: host, script: script, maxOutput: cap) {
                            case .success(let data):
                                done.resume(returning: (host, RemoteTranscriptScript.decode(data, asked: Set(list.map(\.id)))))
                            case .failure(let error):
                                Diagnostics.log("lampmaster: \(host) transcripts not read: \(error.localizedDescription)")
                                done.resume(returning: (host, []))
                            }
                        }
                    }
                }
            }
            var all: [String: [RemoteTranscriptScript.Read]] = [:]
            for await (host, list) in group { all[host] = list }
            return all
        }
        return await cards.remoteSessions(remote, reads: reads)
    }

    private static func facts(_ row: SessionState) -> LampMasterCards.Live? {
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
    nonisolated static var language: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
