import Foundation
import LampBoardCore

/// Whether a session has ever held a conversation.
///
/// WHY THE COLUMN NEEDS TO ASK
/// A row stands for a conversation: what it is doing, whether it wants you, how
/// much room it has left. A `claude` process with no conversation behind it has
/// none of those, and a line for it is a line you can click into an empty
/// window.
///
/// They exist. Reported from use: a project showed two conversations where the
/// editor had one. Both processes were alive — VS Code had started a second
/// `claude` twenty-three seconds after the first and never killed the first —
/// and only one of them had ever said anything. Measured on that machine, six
/// `claude` processes were alive at once, one of them for thirteen days; exactly
/// one had no transcript anywhere, and it was the row that had been reported.
///
/// WHY NOT SIMPLY THE DERIVED PATH
/// `TranscriptLocator` derives where a transcript *would* be, and is right 7065
/// times out of 7066. The exception is the whole reason this type exists rather
/// than a one-line check: a session running in a **git worktree** reports the
/// main repository as its `cwd` while Claude Code files the transcript under the
/// worktree. Refusing a row on "nothing at the derived path" would make every
/// worktree session disappear — and this project is worked on in worktrees.
///
/// So the derived path is the fast answer, and a search by session id across the
/// project folders is the one that settles it. Measured here: 74 folders,
/// 11,788 transcripts, 2 ms per search — and it runs only for the sessions the
/// derivation missed, which is either a worktree (answered once and remembered)
/// or a session that has nothing to find.
@MainActor
final class ConversationIndex {

    /// Sessions proven to have a transcript. A conversation does not un-happen,
    /// so this is only ever added to, and it is what keeps the search off the
    /// hot path for the worktree case.
    private var proven: Set<String> = []

    private let fileManager = FileManager.default

    /// - Parameters:
    ///   - declared: the path the hook carried, when there is one. It has already
    ///     been through `TranscriptPathPolicy`; this only asks whether it exists.
    func hasConversation(sessionId: String, cwd: String, declared: String? = nil) -> Bool {
        guard !sessionId.isEmpty else { return false }
        if proven.contains(sessionId) { return true }

        let derived = TranscriptLocator.candidateURL(sessionId: sessionId, cwd: cwd)
        if fileManager.fileExists(atPath: derived.path) {
            proven.insert(sessionId)
            return true
        }
        if let declared, !declared.isEmpty, fileManager.fileExists(atPath: declared) {
            proven.insert(sessionId)
            return true
        }
        if searchProjects(for: sessionId) {
            proven.insert(sessionId)
            return true
        }
        return false
    }

    /// Whether a `SessionStart` is worth a row on its own.
    ///
    /// `SessionStart` says a process exists. Every other event says something
    /// happened, and only the second is worth a row without asking anything
    /// else.
    ///
    /// The difference was invisible until VS Code began leaving abandoned
    /// `claude` processes behind. Each announces itself exactly like a session
    /// somebody is about to use and then never says another word, and each was
    /// given a line inside the project the person was actually working in,
    /// numbered as if it were a conversation of theirs.
    ///
    /// The cost of this rule, stated because it is real: a **new** session
    /// writes its transcript at its first turn, not when it starts. Measured on
    /// one here, the gap was 101.8 seconds — the time somebody took to type. So
    /// a session opened and not yet spoken to has no row, and gets one the
    /// moment it is used. A resumed session is unaffected: its conversation is
    /// on disk before it announces itself.
    ///
    /// That trade was taken deliberately over the alternative, which is to admit
    /// the row and prune it after some number of minutes. A row that appears and
    /// then vanishes while somebody is looking at the session it belongs to
    /// reads as a fault; a row that has not appeared yet reads as a rule, and it
    /// is one that can be said in a sentence: a row stands for a conversation.
    func startIsWorthARow(_ signal: HookSignal, alreadyKnown: Bool) -> Bool {
        guard signal.event == .sessionStart, !alreadyKnown else { return true }
        // Local only: a host's sessions are confirmed by its own probe, and the
        // transcript this would look for is on the other machine.
        guard signal.host == nil else { return true }
        return hasConversation(
            sessionId: signal.sessionId, cwd: signal.cwd, declared: signal.transcriptPath
        )
    }

    /// The same file under any project folder, which is where a worktree's is.
    ///
    /// A directory listing and one `stat` each rather than an enumerator: the
    /// transcripts are one level down, always, and an enumerator would walk
    /// eleven thousand files to answer a question about one.
    private func searchProjects(for sessionId: String) -> Bool {
        let projects = AppConfig.homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projects.path) else {
            // No folder to look in is not evidence of silence. Saying yes here
            // keeps the row, which is the safe side of this rule: it errs toward
            // showing a session nobody can open rather than hiding one somebody
            // is using.
            return true
        }
        let file = sessionId + ".jsonl"
        for folder in folders {
            let candidate = projects
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) { return true }
        }
        return false
    }
}
