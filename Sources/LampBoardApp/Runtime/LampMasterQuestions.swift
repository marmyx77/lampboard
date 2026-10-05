import LampBoardCore
import Foundation

/// What a session asks through the `lampmaster` MCP server, answered here.
///
/// The lookups read the cards and answer at once, with no model. A question
/// runs the round's isolated `claude`, with Sonnet because a session is waiting
/// for it, under limits decided in Core and inside the same day's ceiling as
/// the rounds.
extension LampMasterService {

    /// The server's queue waits here for an answer. Bounded: a question's own
    /// deadline plus a margin, so a stuck run cannot hold a connection for ever.
    nonisolated func answer(_ body: Data) -> Data {
        let done = DispatchSemaphore(value: 0)
        let reply = Reply()
        Task { @MainActor in
            reply.value = await self.tool(body)
            done.signal()
        }
        guard done.wait(timeout: .now() + LampMasterAsk.timeout + 15) == .success else {
            return Self.encode(text: "LampMaster did not answer in time.", isError: true)
        }
        return Self.encode(text: reply.value.text, isError: reply.value.isError)
    }

    func tool(_ body: Data) async -> (text: String, isError: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = object["tool"] as? String, let tool = LampMasterMCP.Tool(rawValue: name)
        else { return ("Unknown tool.", true) }
        let arguments = object["arguments"] as? [String: Any] ?? [:]
        let asker = (object["session"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        let text = { (key: String) in (arguments[key] as? String).map { String($0.prefix(LampMasterMCP.maxArgument)) } ?? "" }

        let now = Date()
        let sessions = await cards.sessions(live: rows().compactMap(Self.live), now: now)
        switch tool {
        case .overlaps:
            let files = (arguments["files"] as? [String] ?? []).prefix(50).map { String($0.prefix(LampMasterMCP.maxArgument)) }
            guard !files.isEmpty else { return ("Name the files, as paths.", true) }
            return (LampMasterLookup.overlaps(files: Array(files), asker: asker, cwd: cwd, sessions: sessions, now: now), false)
        case .whoKnows:
            let cards = LampMasterLookup.whoKnows(topic: text("topic"), asker: asker, sessions: sessions, now: now)
            // And what was said before the week the cards cover (D89), off the main actor.
            let terms = LampMasterLookup.terms(text("topic")).joined(separator: " ")
            guard let remember, !terms.isEmpty else { return (cards, false) }
            let hits = await Task.detached(priority: .userInitiated) { remember(terms) }.value
            let named = Set(sessions.map(\.card.sessionId))
            return (LampMasterLookup.remembered(hits, asker: asker, named: named, now: now).map { cards + "\n\n" + $0 } ?? cards, false)
        case .precedents:
            guard !text("error").isEmpty else { return ("Paste the error.", true) }
            return (LampMasterLookup.precedents(error: text("error"), asker: asker, sessions: sessions, now: now), false)
        case .askLampMaster:
            return await ask(text("question"), asker: asker, sessions: sessions, now: now)
        }
    }

    /// A question: the switch, the limits, the ceiling, then the run.
    private func ask(
        _ question: String, asker: String?, sessions: [LampMasterSession], now: Date
    ) async -> (text: String, isError: Bool) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("Ask a question.", true) }
        guard questionsRunning < LampMasterAsk.concurrent else {
            return ("LampMaster is already answering \(LampMasterAsk.concurrent) questions. Ask again in a minute.", true)
        }
        guard preferences.lampMasterEnabled else {
            return ("LampMaster is switched off in LampBoard's Settings, so it does not run a model. "
                + "overlaps, who_knows and precedents still answer.", true)
        }
        switch LampMasterAskLimits.decide(history: files.asks(), session: asker, question: question, now: now) {
        case .reuse(let answer): return (answer, false)
        case .refuse(let reason): return (reason, true)
        case .run: break
        }
        guard tokensToday(rounds: files.rounds(), now: now) < LampMasterSchedule.dailyTokenCap else {
            return ("LampMaster has spent today's tokens. overlaps, who_knows and precedents still answer.", true)
        }

        // Booked before the run, not recorded after it: a question waits up to a
        // minute and a half, and every question arriving meanwhile must count it.
        // Nothing awaits between the check above and this line, so on the main
        // actor the two are one step. The session id is the caller's own word,
        // a label for the per-session limit; the hourly total is the real bound.
        let booked = LampMasterAskLimits.Asked(at: now, session: asker, question: question, answer: nil)
        files.record(booked, now: now)
        questionsRunning += 1
        defer { questionsRunning -= 1 }

        // No notebook: it is the one text a past round wrote unchecked, and this
        // answer may go to a session's model rather than past a person's eyes
        // (from the MCP tool; from `/lampmaster` it is printed for the person).
        let frame = LampMasterFrameBuilder.build(sessions: sessions, now: now)
        let text = frame.json()
        let ids = Set(frame.sessions.map(\.id))
        let message = LampMasterAsk.message(question: question, asker: asker, frame: text)
        let system = LampMasterAsk.system(language: Self.language)
        let directory = files.directory
        files.prepare()
        let (run, output) = await Task.detached {
            LampMasterRunner.run(message: message, model: LampMasterAsk.model, system: system,
                                 schema: LampMasterAsk.schema, directory: directory, timeout: LampMasterAsk.timeout)
        }.value

        // The run's own reading expects a round's answer; only its failures to
        // run at all apply here, and the answer is read in its own shape.
        let unrun: Set<LampMasterRun.Failure> = [.unreadable, .reportedError, .timedOut, .notLaunched]
        let answer = run.failure.map(unrun.contains) == true ? nil : LampMasterAnswer.decode(Data(output.utf8))
        guard let answer else {
            files.replace(booked, with: .init(at: now, session: asker, question: question, answer: nil, tokens: run.tokens))
            publish(running: snapshot.running)
            return ("LampMaster could not answer: " + LampMasterLine.reason(run.failure ?? .offSchema) + ".", true)
        }
        let rendered = LampMasterAsk.render(LampMasterAsk.screen(answer, frame: text, ids: ids))
        files.replace(booked, with: .init(at: now, session: asker, question: question, answer: rendered, tokens: run.tokens))
        publish(running: snapshot.running)
        return (rendered, false)
    }

    nonisolated static func encode(text: String, isError: Bool) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["text": text, "isError": isError])) ?? Data("{}".utf8)
    }

    /// The answer, handed from the main actor to the waiting queue; the
    /// semaphore orders the write before the read.
    private final class Reply: @unchecked Sendable {
        var value: (text: String, isError: Bool) = ("", true)
    }
}
