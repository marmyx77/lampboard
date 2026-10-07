import LampBoardCore
import Foundation
import TestKit

/// The mailbox: what may be sent, and what may become a path.
enum MailboxSuite {

    static let suite = TestSuite("Mailbox", [

        // A session id arrives from Claude Code and from HTTP requests, and it is
        // about to be concatenated into a filename. This is the whole defense.
        TestCase("A session id that is not one is refused") { t in
            let hostile = [
                "../../../etc/passwd",
                "a/b",
                "..",
                "with space",
                "semi;colon",
                "$(whoami)",
                "short",                               // under the length floor
                String(repeating: "a", count: 65),     // over the ceiling
                "",
                "unicodé-abcdefgh",
            ]
            for id in hostile {
                t.expect(!Mailbox.isValidSessionId(id), "accepted: \(id)")
                t.expectNil(Mailbox.paths(for: id), "produced paths for: \(id)")
            }
        },

        TestCase("A real session id is accepted") { t in
            t.expect(
                Mailbox.isValidSessionId("f512ecae-4294-45bf-9cf1-fdf45a44dd79"),
                "a uuid must be usable"
            )
            guard let paths = Mailbox.paths(for: "f512ecae-4294-45bf-9cf1-fdf45a44dd79") else {
                return t.fail("no paths for a valid id")
            }
            t.expect(paths.open.path.hasSuffix(".open"), "open marker")
            t.expect(paths.message.path.hasSuffix(".msg"), "message")
            t.expect(paths.pid.path.hasSuffix(".pid"), "pid")
            // All three inside the mailbox and nowhere else.
            for url in [paths.open, paths.message, paths.pid] {
                t.expectEqual(
                    url.deletingLastPathComponent().standardizedFileURL.path,
                    Mailbox.directory.standardizedFileURL.path,
                    "escaped the mailbox: \(url.path)"
                )
            }
        },

        // Empty is refused rather than ignored: delivering it would wake a session
        // to say nothing, and a turn is not free on a busy project.
        TestCase("An empty message is refused") { t in
            for text in ["", "   ", "\n\n", "\t"] {
                guard case .failure(let error) = Mailbox.validate(text) else {
                    return t.fail("accepted whitespace: \(text.debugDescription)")
                }
                t.expectEqual(error, .empty, "reason")
            }
        },

        TestCase("A message is trimmed but otherwise left alone") { t in
            guard case .success(let text) = Mailbox.validate("  ciao\n\nmondo  ") else {
                return t.fail("refused a normal message")
            }
            t.expectEqual(text, "ciao\n\nmondo", "the inside is preserved")
        },

        // Refused rather than truncated: half a pasted stack trace is worse than
        // a clear no, because nothing afterwards says it was cut.
        TestCase("An oversized message is refused, not truncated") { t in
            let huge = String(repeating: "x", count: Mailbox.maxMessageBytes + 1)
            guard case .failure(let error) = Mailbox.validate(huge) else {
                return t.fail("accepted an oversized message")
            }
            guard case .tooLarge = error else {
                return t.fail("wrong reason: \(error)")
            }
        },

        TestCase("The size limit counts bytes, not characters") { t in
            // Emoji are four bytes each: a message that fits by character count
            // can still overflow the file we are about to write.
            let emoji = String(repeating: "🙂", count: Mailbox.maxMessageBytes / 2)
            t.expect(emoji.count < Mailbox.maxMessageBytes, "fits by characters")
            guard case .failure = Mailbox.validate(emoji) else {
                return t.fail("accepted \(emoji.utf8.count) bytes")
            }
        },
    ])
}

/// The mailbox is a capability, not a scratch directory.
enum MailboxPermissionSuite {

    static let suite = TestSuite("Mailbox permissions", [

        // Dropping a file in the mailbox starts a turn in a Claude Code session:
        // it speaks in the user's voice with their tools. The HTTP server already
        // demands a token for the much milder act of raising a window, so the
        // guard here cannot be looser than the one on the token file.
        TestCase("Owner only, exactly like the access token") { t in
            t.expectEqual(Mailbox.directoryPermissions, 0o700, "directory")
            t.expectEqual(Mailbox.filePermissions, 0o600, "files")
        },

        TestCase("The directory is created narrow, and repaired if it was wide") { t in
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lampboard-mailbox-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            setenv(AppConfig.homeOverrideVariable, root.path, 1)
            defer { unsetenv(AppConfig.homeOverrideVariable) }

            // Left wide open by an earlier version, or by somebody's umask.
            try? FileManager.default.createDirectory(
                at: Mailbox.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try? Mailbox.ensureDirectory(using: .default)

            let mode = (try? FileManager.default.attributesOfItem(
                atPath: Mailbox.directory.path
            ))?[.posixPermissions] as? NSNumber
            t.expectEqual(mode?.int16Value, 0o700, "the wide directory was not repaired")
        },
    ])
}

/// What the mailbox path is, before anything is written through it.
///
/// Borrowed from tmux, which does the same check on its socket directory and
/// refuses to run without it: `lstat`, then `S_ISDIR`, then `st_uid == uid`
/// (tmux.c, "directory %s has unsafe permissions"). Creating narrowly is not the
/// same as *being* narrow — `createDirectory` succeeds against a symlink that was
/// already there, and the `chmod` that follows lands on whatever the link points
/// at. Nothing here stops a process running as the user, and nothing can; what it
/// stops is this app widening a directory somewhere else on its behalf.
enum MailboxDirectorySafetySuite {

    /// Runs `body` with the mailbox rooted in a fresh throwaway home.
    private static func inTemporaryHome(_ body: (URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lampboard-mailbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        setenv(AppConfig.homeOverrideVariable, root.path, 1)
        defer { unsetenv(AppConfig.homeOverrideVariable) }

        try? FileManager.default.createDirectory(
            at: Mailbox.directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        body(root)
    }

    static let suite = TestSuite("Mailbox directory safety", [

        TestCase("A clean directory is created and accepted") { t in
            inTemporaryHome { _ in
                t.expectNoThrow("first run") {
                    try Mailbox.ensureDirectory(using: .default)
                }
                t.expectNoThrow("second run over its own directory") {
                    try Mailbox.ensureDirectory(using: .default)
                }
            }
        },

        // The one that was missing. Without the lstat this passes silently and
        // chmods the link's target to 0700 — a directory the app was never asked
        // to touch.
        TestCase("A symlink where the mailbox should be is refused") { t in
            inTemporaryHome { root in
                let elsewhere = root.appendingPathComponent("elsewhere")
                try? FileManager.default.createDirectory(
                    at: elsewhere,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
                try? FileManager.default.createSymbolicLink(
                    at: Mailbox.directory, withDestinationURL: elsewhere
                )

                t.expectThrows(MailboxError.unsafeDirectory(Mailbox.directory.path)) {
                    try Mailbox.ensureDirectory(using: .default)
                }

                let mode = (try? FileManager.default.attributesOfItem(
                    atPath: elsewhere.path
                ))?[.posixPermissions] as? NSNumber
                t.expectEqual(mode?.int16Value, 0o755, "the link target was modified")
            }
        },

        // Both callers of `ensureDirectory` wrap what they catch in
        // `error.localizedDescription`, and for a plain Swift enum Foundation
        // answers that with "The operation couldn't be completed. (error 5.)" —
        // so the one sentence that says what actually went wrong is replaced by a
        // number, at the exact moment somebody needs it.
        TestCase("The error carries its own sentence into localizedDescription") { t in
            for error: MailboxError in [
                .unsafeDirectory("/tmp/x"), .disabled, .empty, .tooLarge(9),
                .invalidSessionId("../x"), .notDelivered("no listener"),
            ] {
                t.expectEqual(
                    (error as Error).localizedDescription,
                    error.description,
                    "\(error) loses its message when wrapped"
                )
            }
        },

        TestCase("A plain file where the mailbox should be is refused by name") { t in
            inTemporaryHome { _ in
                FileManager.default.createFile(
                    atPath: Mailbox.directory.path, contents: Data("x".utf8)
                )
                t.expectThrows(MailboxError.unsafeDirectory(Mailbox.directory.path)) {
                    try Mailbox.ensureDirectory(using: .default)
                }
            }
        },
    ])
}

/// Clearing up after a previous run, without eating what the user wrote.
enum MailboxReapSuite {

    private static let a = "aaaaaaaa-0000-0000-0000-00000000000a"
    private static let b = "bbbbbbbb-0000-0000-0000-00000000000b"

    static let suite = TestSuite("Mailbox reaping", [

        TestCase("A conversation with nothing waiting is released") { t in
            let verdict = MailboxReaper.verdict(forFileNames: ["\(a).open", "\(a).pid"])
            t.expectEqual(verdict.cleared, 1, "cleared")
            t.expectEqual(verdict.delete, ["\(a).open", "\(a).pid"], "both go")
            t.expect(verdict.keptArmed.isEmpty, "nothing to keep")
        },

        // The defect this suite exists for. Quitting the app used to destroy a
        // message that had been dictated, accepted, and was waiting for a sleeping
        // session to stir.
        TestCase("An undelivered message keeps its conversation armed") { t in
            let verdict = MailboxReaper.verdict(
                forFileNames: ["\(a).open", "\(a).msg", "\(a).pid"]
            )
            t.expectEqual(verdict.cleared, 0, "nothing may be cleared")
            t.expectEqual(verdict.keptArmed, [a], "kept armed")
            t.expect(!verdict.delete.contains("\(a).msg"), "the message must never be deleted")
            // And the marker must survive with it: without it no listener will ever
            // arm, so keeping the message alone would be keeping a message nobody
            // can collect.
            t.expect(!verdict.delete.contains("\(a).open"), "the marker must survive too")
            t.expect(verdict.delete.contains("\(a).pid"), "the pid died with the app")
        },

        TestCase("One waiting conversation does not save the others") { t in
            let verdict = MailboxReaper.verdict(
                forFileNames: ["\(a).open", "\(a).msg", "\(b).open", "\(b).pid"]
            )
            t.expectEqual(verdict.cleared, 1, "only b")
            t.expectEqual(verdict.keptArmed, [a], "only a is armed")
            t.expect(verdict.delete.contains("\(b).open"), "b had nothing waiting")
            t.expect(!verdict.delete.contains("\(a).open"), "a did")
        },

        TestCase("Files that are none of our business are left alone") { t in
            let verdict = MailboxReaper.verdict(
                forFileNames: ["writer.log", ".DS_Store", "\(a).open"]
            )
            t.expectEqual(verdict.delete, ["\(a).open"], "only ours")
        },

        TestCase("An empty mailbox is not an error") { t in
            let verdict = MailboxReaper.verdict(forFileNames: [])
            t.expectEqual(verdict.cleared, 0, "cleared")
            t.expect(verdict.delete.isEmpty && verdict.keptArmed.isEmpty, "nothing at all")
        },
    ])
}

/// Sending is off unless the user turned it on.
enum MailboxDisabledSuite {

    static let suite = TestSuite("Sending off by default", [

        // Not a nicety. Dropping a file in the mailbox starts a turn that speaks
        // in the user's voice with their tools, and the reader — a shell script
        // Claude Code spawns — cannot tell who wrote it. Off is the safe state.
        TestCase("A refusal names itself and says where the switch is") { t in
            let description = MailboxError.disabled.description
            t.expect(!description.isEmpty, "silent refusal")
            t.expect(description.contains("Settings › Acting from the panel"), "no way to act on it: \(description)")
        },

        TestCase("Disabled is a distinct outcome, not a generic failure") { t in
            // The window shows different words for "off" and "no window open", and
            // conflating them would send somebody hunting the wrong thing.
            t.expect(MailboxError.disabled != MailboxError.notDelivered("x"), "distinct")
            t.expect(MailboxError.disabled != MailboxError.empty, "distinct")
        },
    ])
}
