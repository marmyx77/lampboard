import Foundation

/// Where a message waits between the chat window and the session it is for.
///
/// # Why files and not a socket
///
/// The reader is not ours. Claude Code spawns it, at a moment we do not choose —
/// the end of a turn — and it has to find the message already there. A socket
/// would need something listening when the sender writes, and the sender writes
/// exactly when the session is busy and nothing is listening.
///
/// A named pipe has the same problem wearing a nicer hat: opening one for writing
/// blocks until a reader opens it, so typing while Claude works would hang the
/// panel. A plain file is late-binding by nature — write it now, let it be read
/// whenever — which is precisely the semantics a chat needs.
///
/// # The four files
///
/// ```
/// ~/.lampboard/inbox/
///   <session>.open   the chat window is open  -> the listener may arm
///   <session>.msg    a message is waiting     -> the listener delivers it
///   <session>.pid    the armed listener's pid -> so it can be reaped
/// ```
///
/// `.open` is the arming condition, and it is what keeps this cheap: a listener
/// blocks only for sessions you are actually chatting with, not for all
/// twenty-four of them.
public enum Mailbox {

    /// Largest message we will carry. Generous for typing, small enough that a
    /// runaway paste cannot fill the disk.
    public static let maxMessageBytes = 64 * 1024

    /// How the message is introduced to the session it is delivered into.
    ///
    /// The wording is load-bearing, not decoration. A message dressed as an
    /// instruction arriving inside a system notification reads exactly like a
    /// prompt injection and gets treated as one — the investigation that found
    /// this mechanism measured eight refusals out of eight with that framing.
    /// Saying plainly where the message came from is both honest and what makes
    /// it work.
    ///
    /// It doubles as a **signature**. A delivered message comes back in the
    /// transcript wearing a `task-notification` origin, indistinguishable from a
    /// background agent reporting in; this line is how the chat window knows the
    /// difference between a system note and something the user typed. See
    /// `TranscriptDecoder`.
    public static let rewakePreamble =
        "The user sent this from the lampboard panel instead of the editor. "
        + "Treat it as their next turn and reply to it directly:"

    /// What the session shows while the message is being delivered.
    public static let rewakeSummary = "message from the lampboard panel"

    /// The mailbox directory.
    public static var directory: URL {
        AppConfig.supportDirectory.appendingPathComponent("inbox", isDirectory: true)
    }

    /// Permissions for the mailbox: owner only, like the access token.
    ///
    /// # Why this is not paranoia
    ///
    /// Dropping a file in here **starts a turn in a Claude Code session** —
    /// it speaks in the user's voice, with their tools and their permissions.
    /// That is a sharper capability than anything else this app exposes, and the
    /// HTTP server already demands a token for the far milder act of raising a
    /// window, on the reasoning that it "raises windows, it doesn't just color
    /// dots".
    ///
    /// Filesystem permissions are the whole guard here, so they had better be the
    /// right ones. `0700`/`0600` stop another account on the machine from reading
    /// queued messages or planting one. They do **not** stop a process running as
    /// the user — nothing on this design can, because the reader is a shell script
    /// Claude Code spawns and it has no way to authenticate who wrote the file.
    /// That limit is real and is recorded in the decision log rather than papered
    /// over.
    public static let directoryPermissions: Int16 = 0o700
    public static let filePermissions: Int16 = 0o600

    /// Creates the mailbox with the right permissions, and repairs them if a
    /// previous version — or somebody's umask — left them wider.
    ///
    /// Checks *what it is repairing* first. Creating narrowly and being narrow are
    /// not the same thing: `createDirectory` succeeds against a symlink that was
    /// already in place, and the `chmod` that follows lands on the link's target —
    /// so a directory this app was never asked to touch gets its permissions
    /// rewritten. tmux makes the same check on its socket directory before it will
    /// run at all, and refuses with "directory %s has unsafe permissions".
    ///
    /// This does not stop a process running as the user; nothing on this design
    /// can. What it stops is the app acting as that process's hands.
    public static func ensureDirectory(using fileManager: FileManager) throws {
        try verifyNothingUnsafeExists(at: directory)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: directoryPermissions], ofItemAtPath: directory.path
        )
    }

    /// Refuses anything at `url` that is not a real directory belonging to us.
    ///
    /// `lstat` and not `stat`, which is the whole point: `stat` follows the symlink
    /// and reports on the target, answering a question nobody asked. Absent is fine —
    /// that is the first run.
    private static func verifyNothingUnsafeExists(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            // Anything other than "it isn't there" is an answer we cannot read, and
            // proceeding blind is what this function exists to prevent.
            guard errno == ENOENT else { throw MailboxError.unsafeDirectory(url.path) }
            return
        }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFDIR, info.st_uid == getuid() else {
            throw MailboxError.unsafeDirectory(url.path)
        }
    }

    /// Narrows a mailbox file to its owner.
    public static func restrict(_ url: URL, using fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.posixPermissions: filePermissions], ofItemAtPath: url.path
        )
    }

    /// `true` when the id is safe to use as a filename.
    ///
    /// Session ids arrive from Claude Code and from HTTP requests, and they are
    /// about to become a path. Anything containing a separator or a dot segment
    /// would let a caller write outside the mailbox — so this is an allow-list of
    /// what a session id has ever been, not a deny-list of what is dangerous.
    public static func isValidSessionId(_ id: String) -> Bool {
        guard (8...64).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The three paths for a session, or `nil` when the id is not usable.
    public static func paths(for sessionId: String) -> Paths? {
        guard isValidSessionId(sessionId) else { return nil }
        return Paths(
            open: directory.appendingPathComponent("\(sessionId).open"),
            message: directory.appendingPathComponent("\(sessionId).msg"),
            pid: directory.appendingPathComponent("\(sessionId).pid")
        )
    }

    public struct Paths: Sendable, Equatable {
        public let open: URL
        public let message: URL
        public let pid: URL
    }

    /// Trims a message and refuses the ones that must never be sent.
    ///
    /// Empty is refused because an accidental Return would otherwise wake a
    /// session to say nothing — which costs a turn, and on a busy project a turn
    /// is not free. Oversized is refused here rather than truncated: half a
    /// pasted stack trace is worse than a clear refusal.
    public static func validate(_ text: String) -> Result<String, MailboxError> {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let size = trimmed.utf8.count
        guard size <= maxMessageBytes else { return .failure(.tooLarge(size)) }
        return .success(trimmed)
    }
}

/// Why a message could not be queued.
///
/// `LocalizedError` and not merely `CustomStringConvertible`: both callers wrap
/// what they catch in `error.localizedDescription`, and Foundation answers that,
/// for a plain Swift enum, with "The operation couldn't be completed. (error 5.)".
/// The sentence below is the only place that says what actually happened, and
/// without this conformance it is replaced by a number on the way to the user.
public enum MailboxError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case empty
    case tooLarge(Int)
    case invalidSessionId(String)
    case notDelivered(String)
    /// Sending is switched off. The default, and a deliberate one.
    case disabled
    /// Something is already at the mailbox path that is not a directory of ours.
    case unsafeDirectory(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .empty:
            return "an empty message would wake the session to say nothing"
        case .tooLarge(let size):
            return "message of \(size) bytes exceeds the limit of \(Mailbox.maxMessageBytes)"
        case .invalidSessionId(let id):
            return "not a usable session id: \(id)"
        case .notDelivered(let reason):
            return reason
        case .disabled:
            return "sending from the panel is off: turn on \"Send messages to sessions\" in Settings › Acting from the panel"
        case .unsafeDirectory(let path):
            return "\(path) is not a directory belonging to this user: refusing to use it"
        }
    }
}

/// What to sweep out of the mailbox after a previous run, and what to leave.
///
/// A decision, so it lives here rather than next to the `FileManager` that carries
/// it out — the first version of this rule was written in the shell, where no test
/// could see it, and it silently destroyed messages.
public enum MailboxReaper {

    public struct Verdict: Sendable, Equatable {
        /// File names to remove.
        public let delete: [String]
        /// Sessions left armed because something of theirs is still undelivered.
        public let keptArmed: [String]
        /// How many conversations were actually released.
        public let cleared: Int
    }

    /// Decides from the mailbox's file names alone.
    ///
    /// The rule in one sentence: **a conversation with an undelivered message keeps
    /// its marker**, everything else goes, and pid files always go because the
    /// process that wrote them died with the app.
    ///
    /// The exception is the whole reason this function exists. A `.msg` on disk is
    /// something the user typed, that the interface accepted, and that has not
    /// arrived because the session was asleep. Sweeping it away on restart is
    /// silent data loss — and removing its marker as well is worse than useless,
    /// because without the marker no listener will ever arm to collect it.
    public static func verdict(forFileNames names: [String]) -> Verdict {
        let waiting = Set(
            names.filter { $0.hasSuffix(".msg") }.map { String($0.dropLast(4)) }
        )

        var delete: [String] = []
        var cleared = 0

        for name in names {
            if name.hasSuffix(".pid") {
                delete.append(name)
            } else if name.hasSuffix(".open") {
                let session = String(name.dropLast(5))
                if !waiting.contains(session) {
                    delete.append(name)
                    cleared += 1
                }
            }
        }

        return Verdict(
            delete: delete.sorted(),
            keptArmed: waiting.sorted(),
            cleared: cleared
        )
    }
}
