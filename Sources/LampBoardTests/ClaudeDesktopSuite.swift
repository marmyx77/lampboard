import LampBoardCore
import Foundation
import TestKit

/// The surface that is entered without a hook, and could not be entered at all
/// through one.
///
/// Every fixture here is the shape measured on a running session, not a shape
/// invented to be easy: the session file, the index beside it, the transcript.
enum ClaudeDesktopSuite {

    /// The index of a live local session, in the shape the application writes.
    private static let index = Data("""
    {"sessionId":"local_8dc98a98-ab0e-44c7-88b9-0ca17121141e",
     "cliSessionId":"792640e6-bced-4316-aae2-b6b6427a357c",
     "cwd":"/Users/dev/Library/Application Support/Claude/local-agent-mode-sessions/o/u/local_8dc98a98/outputs",
     "userSelectedFolders":["/Users/dev/Documents/client"],
     "resolvedFolderKinds":[{"display":"/Users/dev/Documents/client","kind":"local"}],
     "spaceId":"fc72310d-6863-469b-a649-165d3b0dedec",
     "title":"File analysis","titleSource":"auto",
     "createdAt":1788116580531,"lastActivityAt":1788122678265,
     "model":"claude-opus-5","isArchived":false}
    """.utf8)

    /// 30 August 2026, 22:44:38 in Turin: the moment the measured conversation
    /// wrote its last word, and the moment its agent process was removed.
    private static let lastActivity = Date(timeIntervalSince1970: 1_788_122_678.265)

    private static func read(_ data: Data = index) -> DesktopSessionIndex? {
        DesktopSessionIndex.parse(data)
    }

    static let suite = TestSuite("Claude Desktop", [

        TestCase("The folder of a conversation comes from the index, never from the session's cwd") { t in
            // The session file's `cwd` is the session's own `outputs` directory.
            // Read as a workspace it would put every Claude Desktop row in a
            // folder called `outputs`, inside the application's data, which is
            // both wrong and unusable — you cannot go there and it is not your
            // project. The folder you connected is only written here.
            guard let read = DesktopSessionIndex.parse(index) else {
                t.expect(false, "the index did not parse")
                return
            }
            t.expectEqual(read.folders, ["/Users/dev/Documents/client"], "the folder you connected")
            t.expectEqual(read.title, "File analysis", "and the name it gave itself")
            t.expectEqual(read.model, "claude-opus-5", "and the model, for the ring")
            t.expect(!read.isArchived, "and whether it is still one of yours")

            // The transcript is asked for by name rather than found by rebuilding
            // the folder encoding, which is the application's business and has
            // changed before.
            t.expectEqual(read.cliSessionId, "792640e6-bced-4316-aae2-b6b6427a357c", "the transcript")
            t.expectEqual(read.lastActivityAt, lastActivity, "and when it last moved")
        },

        TestCase("The application says itself whether the work is on this machine") { t in
            // `resolvedFolderKinds[].kind` is the only field that separates a
            // session running here from one running on a server, and it is the
            // application's own answer rather than an inference of ours. A cloud
            // session leaves nothing on this Mac to read, so a row for it can
            // never be more than presence.
            t.expect(DesktopSessionIndex.parse(index)?.hasLocalFolder == true, "local")

            let remote = Data("""
            {"userSelectedFolders":["/Users/dev/Documents/client"],
             "resolvedFolderKinds":[{"display":"/Users/dev/Documents/client","kind":"remote"}]}
            """.utf8)
            t.expect(DesktopSessionIndex.parse(remote)?.hasLocalFolder == false, "not local")

            let silent = Data(#"{"userSelectedFolders":["/Users/dev/x"]}"#.utf8)
            t.expect(DesktopSessionIndex.parse(silent)?.hasLocalFolder == false,
                     "and silence is not a yes")
        },

        TestCase("An index that says nothing usable is refused rather than filled in") { t in
            t.expectNil(DesktopSessionIndex.parse(Data("not json".utf8)), "nonsense")
            let empty = DesktopSessionIndex.parse(Data("{}".utf8))
            t.expect(empty != nil, "an empty object is still an index")
            t.expect(empty?.folders.isEmpty == true, "with no folder claimed")
            t.expectNil(empty?.title, "and no name invented")
            t.expectNil(empty?.lastActivityAt, "and no moment at the epoch")
            t.expectNil(
                DesktopSessionIndex.parse(Data(#"{"lastActivityAt":"soon"}"#.utf8))?.lastActivityAt,
                "a moment of the wrong shape is no moment"
            )

            // A folder that is not a path is not a folder: these strings reach a
            // row label and, through it, a click.
            let bad = Data(#"{"userSelectedFolders":["","~/relative","/Users/dev/ok"]}"#.utf8)
            t.expectEqual(DesktopSessionIndex.parse(bad)?.folders, ["/Users/dev/ok"], "only real paths")

            // A conversation can hold a local folder and a remote one at once,
            // and only the local one is a place this Mac can open.
            let mixed = Data("""
            {"userSelectedFolders":["/Users/dev/here","/Users/dev/there"],
             "resolvedFolderKinds":[{"display":"/Users/dev/here","kind":"local"},
                                    {"display":"/Users/dev/there","kind":"remote"}]}
            """.utf8)
            t.expectEqual(
                DesktopSessionIndex.parse(mixed)?.localFolders, ["/Users/dev/here"],
                "the row is labelled with the folder that is here"
            )
        },

        TestCase("A home names its index, and only a home does") { t in
            let home = URL(fileURLWithPath: "/Users/dev/Library/x/local_abc")
            t.expectEqual(
                ClaudeDesktop.indexPath(forHome: home).lastPathComponent, "local_abc.json",
                "the index sits beside the home and carries its name"
            )
            t.expect(ClaudeDesktop.isSessionHome("local_abc"), "a home")
            t.expect(!ClaudeDesktop.isSessionHome("local_abc.json"), "the index is not one")
            t.expect(!ClaudeDesktop.isSessionHome("spaces"), "nor anything else in there")
        },

        TestCase("A row that was found keeps the folder it was found in") { t in
            // The hole a second audit found, and it was open on every row this
            // panel discovers rather than receives. `POST /signal` is not
            // authenticated: a hook naming a session id that already exists, with
            // a `cwd` that happens to match some other open window, used to move
            // that row into the other project — folder, click and all.
            //
            // A Codex row's folder came out of the rollout a live process holds
            // open. A Claude Desktop row's came out of the index beside its
            // session home. Both were established before any hook existed, so a
            // hook may move the colour and nothing else.
            let moment = Date(timeIntervalSince1970: 1_760_000_000)
            func session(harness: Harness, entrypoint: String?) -> SessionState {
                SessionState(
                    id: "s", status: .idle, workspace: Workspace(path: "/dev/project-a"),
                    updatedAt: moment, statusSince: moment, harness: harness, entrypoint: entrypoint
                )
            }

            t.expect(session(harness: .codex, entrypoint: "codex-commandLine").wasFound,
                     "a Codex row was found, not announced")
            t.expect(session(harness: .claudeCode, entrypoint: ClaudeDesktop.entrypoint).wasFound,
                     "and so was a Claude Desktop one")
            // The application's other name, the one its hooks carry since 2.1.281:
            // a row born of those hooks is the same surface and gets the same
            // treatment, or its click goes looking for an editor window.
            t.expect(session(harness: .claudeCode, entrypoint: ClaudeDesktop.hookEntrypoint).wasFound,
                     "under the name the hooks use too")
            t.expect(ClaudeDesktop.isEntrypoint("claude-desktop") && ClaudeDesktop.isEntrypoint("local-agent"),
                     "both spellings are the application")
            t.expect(!ClaudeDesktop.isEntrypoint("claude-vscode") && !ClaudeDesktop.isEntrypoint(nil),
                     "and nothing else is")
            t.expect(
                !DeepLinkPolicy.opensNewConversation(harness: .claudeCode, entrypoint: "claude-desktop"),
                "no editor tab to open for a desktop conversation, whichever name it came in under"
            )

            // The other side of the rule, which must keep working: a Claude Code
            // session that announces itself really does move when its folder is
            // opened in an editor, and that is D25 rather than a defect.
            t.expect(!session(harness: .claudeCode, entrypoint: "claude-vscode").wasFound,
                     "an announced row still follows the latest resolution")
            t.expect(!session(harness: .claudeCode, entrypoint: "cli").wasFound,
                     "including one in a terminal")
        },

        TestCase("A conversation whose turn has ended is still a conversation") { t in
            // The defect, and the reason this surface was rebuilt. The first
            // version asked the question every other row asks — which session
            // file names a live process? — and a Claude Desktop agent process
            // lives exactly **one turn**. The application starts it to answer
            // and removes its file when it exits: measured on 30 August, a turn
            // whose last word landed at 22:44:38 left an empty `.claude/sessions`
            // directory stamped 22:44.
            //
            // So the row appeared while the model was working and disappeared at
            // the very moment there was something to read, which is the one
            // moment this panel exists for. Presence cannot come from a process
            // that is meant to end.
            guard let index = read() else {
                t.expect(false, "the index did not parse")
                return
            }
            let horizon = lastActivity.addingTimeInterval(-AppConfig.sessionStaleAfter)
            t.expect(
                DesktopConversation.deservesRow(index, since: horizon),
                "the conversation is a row with no process left alive"
            )
            t.expectEqual(
                DesktopConversation.derivation(
                    isAnswering: false, phase: .answered,
                    lastActivity: lastActivity, observedAt: lastActivity.addingTimeInterval(300)
                ).status,
                .ready,
                "and the answer nobody has read is green, not gone"
            )
        },

        TestCase("Three gates bound the column, and each is the application's own answer") { t in
            let horizon = lastActivity.addingTimeInterval(-AppConfig.sessionStaleAfter)

            // Fifty-one conversations sit on the machine this was written on,
            // going back to April. Without a horizon every one of them is a row.
            let old = Data("""
            {"resolvedFolderKinds":[{"display":"/Users/dev/x","kind":"local"}],
             "lastActivityAt":1752000000000}
            """.utf8)
            t.expect(!DesktopConversation.deservesRow(read(old)!, since: horizon),
                     "a conversation from July is not news")

            // A cloud session leaves nothing on this Mac to read, so there is
            // nothing a row could honestly say about it.
            let remote = Data("""
            {"resolvedFolderKinds":[{"display":"/Users/dev/x","kind":"remote"}],
             "lastActivityAt":1788122678265}
            """.utf8)
            t.expect(!DesktopConversation.deservesRow(read(remote)!, since: horizon),
                     "work on a server is not work on this machine")

            // Archiving is the person saying they are done with it.
            let archived = Data("""
            {"resolvedFolderKinds":[{"display":"/Users/dev/x","kind":"local"}],
             "lastActivityAt":1788122678265,"isArchived":true}
            """.utf8)
            t.expect(!DesktopConversation.deservesRow(read(archived)!, since: horizon),
                     "and a conversation you filed away stays filed away")

            // Silence is not a date. An index with no moment cannot be placed on
            // either side of the horizon, so it is not placed at all.
            let silent = Data(#"{"resolvedFolderKinds":[{"display":"/Users/dev/x","kind":"local"}]}"#.utf8)
            t.expect(!DesktopConversation.deservesRow(read(silent)!, since: horizon),
                     "nor is a conversation that never said when")
        },

        TestCase("A turn in flight outranks the transcript behind it") { t in
            // The transcript is what has been written so far, and a model that
            // has just been asked a question has written nothing yet. Reading it
            // alone, the first seconds of every turn are the end of the previous
            // one: the row goes green for an instant before it goes yellow, on
            // the very glance the panel is for.
            let written = lastActivity
            let looked = lastActivity.addingTimeInterval(300)

            let inFlight = DesktopConversation.derivation(
                isAnswering: true, phase: .answered, lastActivity: written, observedAt: looked
            )
            t.expectEqual(inFlight.status, .working,
                          "a process holding the session file is a turn in flight")
            // And it is dated by the looking, not by the transcript. A turn that
            // has just started has written nothing yet: dated by the transcript
            // this colour is older than the answer it replaces, and a row that
            // was cleared a moment ago could never go yellow again.
            t.expectEqual(inFlight.moment, looked, "a thing that is true now is dated now")

            let read = DesktopConversation.derivation(
                isAnswering: false, phase: .answered, lastActivity: written, observedAt: looked
            )
            t.expectEqual(read.moment, written,
                          "while a record of something that happened is dated when it happened")
            t.expectEqual(
                DesktopConversation.derivation(
                    isAnswering: false, phase: nil, lastActivity: written, observedAt: looked
                ).status,
                .idle,
                "and a transcript that says nothing readable says nothing"
            )
        },

        TestCase("A derived colour moves a row forward, and a click is never undone") { t in
            // The second defect, and it was silent. This row's colour is not
            // reported by a hook; it is re-read off the transcript every five
            // seconds. Adoption is the wrong verb for that — `.adopt` refuses to
            // overwrite a row that exists, by contract — so every update after
            // the first was a no-op and the row kept the colour it was born
            // with, for ever.
            //
            // The action that replaced it carries the moment, because a colour
            // re-asserted on a timer would otherwise undo the click: you clear a
            // green row, five seconds later the transcript still ends in the
            // same answer, and it lights up again for something you have read.
            let born = Date(timeIntervalSince1970: 1_788_122_000)
            let answered = born.addingTimeInterval(60)
            let session = SessionState(
                id: "s", status: .working, workspace: Workspace(path: "/dev/client"),
                updatedAt: born, statusSince: born, entrypoint: ClaudeDesktop.entrypoint
            )
            let working = TrafficLightState(sessions: ["s": session])

            let green = StateReducer.reduce(
                working, action: .derive(sessionId: "s", status: .ready, at: answered),
                now: answered
            )
            t.expectEqual(green.sessions["s"]?.status, .ready, "the answer arrives")

            let seen = StateReducer.reduce(
                green, action: .markSeen(sessionId: "s"), now: answered.addingTimeInterval(10)
            )
            t.expectEqual(seen.sessions["s"]?.status, .idle, "the click clears it")

            // The transcript has not changed: the next sweep re-derives the same
            // answer, dated when it was written, which is now behind the click.
            let after = StateReducer.reduce(
                seen, action: .derive(sessionId: "s", status: .ready, at: answered),
                now: answered.addingTimeInterval(15)
            )
            t.expectEqual(after.sessions["s"]?.status, .idle, "and the sweep leaves it cleared")

            // A row nobody knows is not invented by a derivation: presence is
            // adoption's business, and only adoption's.
            let ghost = StateReducer.reduce(
                .empty, action: .derive(sessionId: "s", status: .ready, at: answered), now: answered
            )
            t.expect(ghost.sessions.isEmpty, "and nothing is conjured for a row that is not there")
        },

        TestCase("A found row keeps its transcript, its surface and its agent too") { t in
            // The other half of the same hole, which the first fix did not
            // cover. `POST /signal` carries no token, so a hook naming a session
            // id this machine discovered is a claim about it, and the claim
            // loses against what was read from a live process.
            //
            // Each of these three is a different promise the row makes. The
            // transcript path is the thread back to the conversation. The
            // entrypoint decides whether a click raises a terminal, an editor or
            // an application — a Codex row relabelled `claude-vscode` gets an
            // editor window opened for a conversation that is not in one. And
            // the harness is what `wasFound` itself is read from, so a claim
            // that moved it would unlock the other two.
            let moment = Date(timeIntervalSince1970: 1_760_000_000)
            let found = SessionState(
                id: "s", status: .idle, workspace: Workspace(path: "/dev/project"),
                updatedAt: moment, statusSince: moment, harness: .codex,
                transcriptPath: "/dev/rollout.jsonl", entrypoint: "codex-commandLine"
            )
            let state = TrafficLightState(sessions: ["s": found])

            let claim = HookSignal(
                sessionId: "s", event: .userPromptSubmit, cwd: "/dev/elsewhere",
                entrypoint: "claude-vscode",
                transcriptPath: "/dev/somebody-elses.jsonl", harness: .claudeCode
            )
            let after = StateReducer.reduce(
                state, action: .signal(claim, workspace: Workspace(path: "/dev/elsewhere")),
                now: moment.addingTimeInterval(60)
            )
            guard let row = after.sessions["s"] else {
                t.expect(false, "the row disappeared entirely")
                return
            }
            t.expectEqual(row.workspace.path, "/dev/project", "the folder it was found in")
            t.expectEqual(row.transcriptPath, "/dev/rollout.jsonl", "the file it was found through")
            t.expectEqual(row.entrypoint, "codex-commandLine", "the surface its binary proved")
            t.expectEqual(row.harness, .codex, "and the agent it actually belongs to")

            // The colour is the one thing a hook may still move, because that is
            // the one thing it is better placed to know.
            t.expectEqual(row.status, .working, "what the hook is for")
        },

        TestCase("Not even the branch that keeps Codex out of red may move a found row") { t in
            // The exception a third audit found, three lines under the comment
            // that said there was none. `Harness.cannotReport` stops a Codex row
            // ever turning red, and that branch returned early — before the
            // protected folder was worked out — applying the signal's own.
            //
            // The running app never reached it, because the store substitutes
            // the known folder before calling in. That is precisely the
            // dependence on one caller that moving the rule in here was supposed
            // to remove: a second caller, one day, and the protection is gone
            // with nothing to say so.
            let moment = Date(timeIntervalSince1970: 1_760_000_000)
            let found = SessionState(
                id: "s", status: .idle, workspace: Workspace(path: "/dev/project"),
                updatedAt: moment, statusSince: moment, harness: .codex,
                transcriptPath: "/dev/rollout.jsonl", entrypoint: "codex-commandLine"
            )
            let state = TrafficLightState(sessions: ["s": found])

            let claim = HookSignal(
                sessionId: "s", event: .stopFailure, cwd: "/dev/elsewhere",
                failureReason: .unknown, harness: .codex
            )
            let after = StateReducer.reduce(
                state, action: .signal(claim, workspace: Workspace(path: "/dev/elsewhere")),
                now: moment.addingTimeInterval(60)
            )
            t.expectEqual(after.sessions["s"]?.workspace.path, "/dev/project",
                          "the folder it was found in, whatever the payload said")
            t.expect(after.sessions["s"]?.status != .failed,
                     "and Codex still never turns red, which is why the branch exists")
        },

        TestCase("A turn that is running is told from one that has ended") { t in
            // The two records at the end of a real transcript, measured while a
            // session was working: the assistant asks for a tool, the user hands
            // the result back. Neither is an answer to read.
            let mid = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read"}]},"timestamp":"2026-08-30T19:04:19.801Z"}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]},"timestamp":"2026-08-30T19:04:22.803Z"}
            """
            t.expectEqual(TranscriptTurn.phase(inTailChunk: mid, isWholeFile: true), .running,
                          "a tool result is the middle of a turn")

            let done = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]},"timestamp":"2026-08-30T19:04:22.803Z"}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"timestamp":"2026-08-30T19:04:31.000Z"}
            """
            t.expectEqual(TranscriptTurn.phase(inTailChunk: done, isWholeFile: true), .answered,
                          "the assistant speaking in words is the end of one")
        },

        TestCase("A sentence followed by a tool call is not an answer") { t in
            // The case that would have painted green over a session still
            // working: a model routinely says what it is about to do and then
            // does it, in one message. The last thing it did is the tool call.
            let both = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","name":"Grep"}]},"timestamp":"2026-08-30T19:04:19.801Z"}
            """
            t.expectEqual(TranscriptTurn.phase(inTailChunk: both, isWholeFile: true), .running,
                          "the tool call is the last thing it did")
        },

        TestCase("Bookkeeping appended by tooling is stepped over, not read as a turn") { t in
            // The same rows that once made three projects look active: written
            // around the session rather than by it. They move the file and say
            // nothing about whose floor it is.
            let noisy = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"timestamp":"2026-08-30T19:04:31.000Z"}
            {"type":"last-prompt","id":"x"}
            {"type":"bridge-session","id":"y"}
            """
            t.expectEqual(TranscriptTurn.phase(inTailChunk: noisy, isWholeFile: true), .answered,
                          "the answer is still the last thing said")
        },

        TestCase("A chunk read from the end drops its first, broken line") { t in
            // Read from the end of a large file, the first line starts mid-way.
            // Parsing it would at best fail and at worst find a `type` inside a
            // truncated string.
            let cut = """
            ntent":[{"type":"text","text":"cut in half"}]},"timestamp":"2026-08-30T19:00:00.000Z"}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]},"timestamp":"2026-08-30T19:04:19.801Z"}
            """
            t.expectEqual(TranscriptTurn.phase(inTailChunk: cut), .running, "the whole line decides")
            t.expectNil(TranscriptTurn.phase(inTailChunk: "garbage\nmore garbage", isWholeFile: true),
                        "and nothing readable is no answer, never a colour")
            t.expectNil(TranscriptTurn.phase(inTailChunk: "", isWholeFile: true), "nor is nothing")
        },
    ])
}
