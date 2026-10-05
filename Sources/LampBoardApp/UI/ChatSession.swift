import LampBoardCore
import Combine
import Foundation
import SwiftUI

/// What one chat window is looking at.
///
/// It holds two things that update on different clocks and must not be confused:
/// the **conversation**, which comes from the transcript on disk, and the
/// **status**, which comes from the hooks. The transcript says what was said; the
/// traffic light says whether anything is coming. A window that inferred one from
/// the other would be wrong in both directions — a long silence is not an idle
/// session, and a green dot is not a message.
@MainActor
final class ChatSession: ObservableObject {

    @Published private(set) var conversation: Conversation
    @Published private(set) var status: SessionStatus
    @Published private(set) var unread: Int = 0

    /// A message written but not yet picked up by the session.
    ///
    /// Shown to the user, because the delay is real and unexplained waiting is
    /// what makes a chat feel broken: if Claude is mid-turn the message sits on
    /// disk until that turn ends, which can be minutes.
    @Published private(set) var pending: String?

    /// Text put into the composer for the person to read, change and send —
    /// LampMaster's proposed question or reply (D85). Never sent by itself.
    @Published var proposed: String?

    /// Why the last send failed, if it did.
    @Published private(set) var sendError: String?

    /// `true` when a listener is armed and a message would be picked up promptly.
    ///
    /// False is the cold start: the chat window is open, but no turn has ended
    /// since, so nothing is waiting to carry a message. It resolves itself the
    /// moment the session does anything at all — and until then the window says
    /// so instead of showing a spinner for something that will not happen.
    @Published private(set) var listening = false

    /// `true` when answering from the panel is switched on.
    ///
    /// Off is the default and the safe resting state — see D15. The composer is
    /// disabled rather than hidden, because a chat window with no visible way to
    /// answer reads as broken, and one that accepts text going nowhere is worse.
    var canSend: Bool { mailbox.isSendingEnabled }

    let sessionId: String
    let workspace: Workspace

    private let store: StateStore
    private let reader: TranscriptReader
    private let mailbox: MailboxWriter
    private let box: PeerSender
    /// The session has Claude Code's own box (D81): a message goes there, at
    /// once, and the mailbox of D15 stays for sessions without one.
    private var hasBox = false
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// When the user last had this window in front of them.
    private var lastRead: Date?

    init(session: SessionState, store: StateStore, mailbox: MailboxWriter = MailboxWriter(), box: PeerSender = PeerSender()) {
        self.mailbox = mailbox
        self.box = box
        // A session on another machine has its box there, not here.
        self.hasBox = session.workspace.host == nil && box.hasBox(sessionId: session.id)
        self.sessionId = session.id
        self.workspace = session.workspace
        self.store = store
        self.status = session.status
        self.conversation = Conversation(sessionId: session.id)
        self.reader = TranscriptReader(path: Self.transcriptPath(for: session))
    }

    /// Where to read from: what the hooks said, or a checked guess.
    ///
    /// A session adopted from `~/.claude/sessions/` carries no transcript path,
    /// and after a restart of lampboard that is every session — so without the
    /// fallback the chat window would stay empty until somebody pressed enter
    /// again. The derived path is **verified on disk** before being used, because
    /// it is wrong for sessions running in a git worktree, where `cwd` reports the
    /// main repository and the transcript is filed under the worktree.
    private static func transcriptPath(for session: SessionState) -> String {
        if let known = session.transcriptPath { return known }

        let candidate = TranscriptLocator.candidateURL(
            sessionId: session.id, cwd: session.workspace.path
        )
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : ""
    }

    /// `true` when there is a transcript to read at all.
    ///
    /// False for a session adopted from the filesystem before any hook fired. The
    /// window says so instead of showing an empty conversation, which would read
    /// as "nothing was said here".
    var hasTranscript: Bool { !reader.path.isEmpty }

    // MARK: - Lifecycle

    func start() {
        listening = hasBox || mailbox.isListening(sessionId: sessionId)
        guard hasTranscript else { return }
        loadEverything()
        followStatus()
        startPolling()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
    }

    // MARK: - Sending

    /// Leaves a message for the session.
    ///
    /// Returns `true` when it was written. Written is **not** delivered: if the
    /// session is mid-turn the message waits on disk until the turn ends, which
    /// is why `pending` exists and why the composer clears only on success.
    @discardableResult
    func send(_ text: String) -> Bool {
        sendError = nil
        if hasBox { return sendThroughBox(text) }
        return sendThroughMailbox(text)
    }

    private func sendThroughMailbox(_ text: String) -> Bool {
        switch mailbox.send(text, to: sessionId) {
        case .success:
            pending = text.trimmed
            Diagnostics.log("chat \(sessionId): queued \(text.trimmed.count) chars")
            return true
        case .failure(let error):
            sendError = error.description
            Diagnostics.log("chat \(sessionId): send refused: \(error.description)")
            return false
        }
    }

    /// How long a message through the box may stay unseen in the conversation
    /// before the composer stops saying it is on its way.
    static let boxReceiptWithin: TimeInterval = 60

    /// Through Claude Code's box: idle, the session starts a turn on it; busy,
    /// it takes it into the running one. Pending until the conversation shows it.
    /// A box gone since the window opened sends it through the mailbox instead.
    private func sendThroughBox(_ text: String) -> Bool {
        guard mailbox.isSendingEnabled else {
            sendError = MailboxError.disabled.description
            return false
        }
        let typed = text.trimmed
        let id = sessionId
        let box = self.box
        pending = typed
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = box.send(typed, to: id)
            // Unwrapped before the hop, as `loadEverything` does: inside it,
            // Swift 6 rejects the capture.
            guard let self else { return }
            await MainActor.run {
                switch result {
                case .success:
                    Diagnostics.log("chat \(id): \(typed.count) chars into the session's box")
                    self.expectReceipt(of: typed)
                case .failure(.noBox):
                    if self.pending == typed { self.pending = nil }
                    self.hasBox = false
                    Diagnostics.log("chat \(id): its box is gone, through the mailbox")
                    _ = self.sendThroughMailbox(typed)
                case .failure(let failure):
                    if self.pending == typed { self.pending = nil }
                    self.sendError = failure.description
                    self.hasBox = box.hasBox(sessionId: id)
                    Diagnostics.log("chat \(id): box refused: \(failure.description)")
                }
            }
        }
        return true
    }

    /// The box says nothing back: if the conversation has not shown the message
    /// within a minute, the composer says so instead of waiting forever.
    private func expectReceipt(of typed: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.boxReceiptWithin) { [weak self] in
            guard let self, self.pending == typed else { return }
            self.pending = nil
            self.sendError = "sent to the session's box, but not in its conversation after a minute"
        }
    }

    /// The window came to the front: everything in it counts as read.
    func markRead() {
        lastRead = Date()
        unread = 0
    }

    // MARK: - Reading

    /// `true` while the first read runs off the main actor: the poll must not
    /// touch the reader until it is back.
    private var isLoading = false

    /// The first read, **off the main actor**.
    ///
    /// It reads the transcript's tail (`TranscriptReader.readAll`, a few
    /// megabytes at most) and parses it; even bounded, that is work the window
    /// should not make the whole app wait for. The reader is handed to the task
    /// and not touched by the poll until the task hands it back.
    private func loadEverything() {
        isLoading = true
        let reader = self.reader
        let id = sessionId
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = reader.readAll()
            let title = reader.title
            let skipped = reader.skippedBytes
            // Weak across the read — a 466 MB transcript is the reason this is
            // detached at all — and a plain value once it is over. Unwrapping
            // inside the hop makes that closure capture the variable, which
            // Swift 6 rejects outright.
            guard let self else { return }
            await MainActor.run {
                self.isLoading = false
                var shown = entries
                if skipped > 0 {
                    // The window opened on the tail of a long file. Say so where
                    // the reader would otherwise look for what came before.
                    let megabytes = Double(skipped) / 1_048_576
                    shown.insert(TranscriptEntry(
                        id: "lampboard.window.\(id)", kind: .note,
                        text: String(format: "The first %.0f MB of this transcript are not loaded: the window shows its tail.", megabytes),
                        timestamp: entries.first?.timestamp ?? Date()
                    ), at: 0)
                }
                self.conversation = Conversation(sessionId: id, title: title, entries: shown)
                    .trimmed(to: AppConfig.chatHistoryLimit)

                // An empty window has two very different causes — the file wasn't
                // there, or it was there and nothing in it was recognized — and
                // they look identical on screen. This is the line that tells them
                // apart.
                Diagnostics.log("""
                chat \(id): \(entries.count) entries from \(reader.path) \
                (\(entries.filter { $0.kind == .human }.count) human, \
                \(entries.filter { $0.kind == .assistant }.count) assistant) \
                title=\(title ?? "<none>") skipped=\(skipped) bytes
                """)
                // Opening a window is reading it: the count starts from now, not
                // from the beginning of a conversation that may be three days old.
                self.markRead()
            }
        }
    }

    private func refresh() {
        guard !isLoading else { return }
        // Before the early return below, on purpose. The listener takes the
        // message off disk seconds before the turn produces anything to read, and
        // behind that guard the composer would keep saying "waiting" for a message
        // that had already gone.
        if pending != nil, !hasBox, !mailbox.hasPending(sessionId: sessionId) {
            pending = nil
        }
        listening = hasBox || mailbox.isListening(sessionId: sessionId)

        let fresh = reader.readNewEntries()
        // Through the box, a message has gone when the conversation shows it.
        if let pending, hasBox, fresh.contains(where: { $0.kind == .human && $0.text == pending }) {
            self.pending = nil
        }
        guard !fresh.isEmpty || reader.title != conversation.title else { return }

        conversation = conversation
            .appending(fresh, title: reader.title)
            .trimmed(to: AppConfig.chatHistoryLimit)
        unread = conversation.unreadCount(since: lastRead)

        if !fresh.isEmpty {
            Diagnostics.log(
                "chat \(sessionId): +\(fresh.count) entries, \(unread) unread"
            )
        }
    }

    /// Polling, and not a filesystem watcher.
    ///
    /// `DispatchSource` on a file that gets replaced — which a transcript does, on
    /// `/clear` and on a fork — needs re-arming on a vnode that no longer exists,
    /// and getting that wrong stops the window updating with no visible symptom. A
    /// one-second `stat` costs nothing next to being silently frozen, and the
    /// reader already returns immediately when the size hasn't moved.
    private func startPolling() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.transcriptPollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The dot in the header follows the column, because it *is* the column: the
    /// same state, read from the same store, so the two can never disagree.
    private func followStatus() {
        store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, let session = state.sessions[self.sessionId] else { return }
                self.status = session.status
            }
            .store(in: &cancellables)
    }
}
