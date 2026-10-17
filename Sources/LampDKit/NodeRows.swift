import Foundation
import LampBoardCore

/// The rows of this machine, from one look at its files.
///
/// Built on `V1ProbeSource.rows(from:identity:at:)`, the function that makes the
/// phone's rows of a machine read over ssh: the lamp of each row — its status,
/// when it last spoke, its context, where tmux holds it — is that function's,
/// unchanged. What this adds is only what a machine knows of itself and the phone
/// cannot ask in one look: a background session's job (its summary, what it
/// waits for, the id `claude attach` takes), and the person's choices.
///
/// A row's state is still learned from the file and not heard (`stateBasis` is
/// `sessionFile`) until `lampd` takes the hooks in W5: an answer to read and red
/// do not show, and an amber row carries no question.
public enum NodeRows {

    /// The lamp-bearing rows of `reading`, before the person's choices.
    public static func rows(from reading: V1ProbeReading, jobs: [String: BackgroundJob],
                            identity: V1SourceIdentity, at now: Date) -> [V1Row] {
        V1ProbeSource.rows(from: reading.report, identity: identity, at: now).map { row in
            // The machine is this one: it is never unreachable from here, and
            // when it was last looked at is the state's age in `hello`, not a
            // field that would change every row at every look.
            var extras = row.extras
            extras.hostProbedAt = nil
            extras.hostReachable = true
            let session = jobs[row.id].map { row.session.with(job: $0) } ?? row.session
            return V1Row(session: session, source: row.source, owner: row.owner, extras: extras)
        }
    }

    /// The rows the column shows: `fresh` as the person left them.
    public static func shown(_ fresh: [V1Row], preferences: RowPreferences) -> [V1Row] {
        fresh.compactMap { preferences.applied(to: $0) }
    }
}

extension SessionSnapshot {
    /// The same snapshot with what a background session's job file says.
    public func with(job: BackgroundJob) -> SessionSnapshot {
        SessionSnapshot(
            id: id, status: status, workspace: workspace, path: path,
            updatedAt: updatedAt, statusSince: statusSince, activeSubagents: activeSubagents,
            harness: harness, pendingAsk: pendingAsk, waitingOn: waitingOn,
            contextPercent: contextPercent, contextTokens: contextTokens, contextWindow: contextWindow,
            contextModel: contextModel, contextConfidence: contextConfidence, costUSD: costUSD,
            failureReason: failureReason, lastMessage: lastMessage, muted: muted,
            slot: slot, transcriptPath: transcriptPath, git: git, host: host, entrypoint: entrypoint,
            origin: origin, title: title, jobId: job.id, summary: job.summary ?? summary, needs: job.needs,
            unreadAnswers: unreadAnswers, label: label
        )
    }
}
