import LampBoardCore
import Foundation
import TestKit

/// Running an outside tool without being taken hostage by it.
///
/// Both cases here are ones the obvious code gets wrong silently. A tool that
/// hangs takes the caller with it forever, and a tool that writes more than a
/// pipe holds deadlocks against a caller that waits before reading — neither
/// raises anything, neither logs anything, and both look exactly like slowness
/// until somebody finally kills the app. They are tested with real processes
/// because a mock of a pipe would prove nothing about a pipe.
enum CommandSuite {

    static let suite = TestSuite("Running a tool", [

        TestCase("What the tool says comes back with its exit code") { t in
            do {
                let result = try Command.run("/bin/echo", ["hello"], deadline: 10)
                t.expectEqual(result.status, 0, "status")
                t.expectEqual(result.output, "hello\n", "output")
                t.expect(result.succeeded, "succeeded")
            } catch {
                t.fail("echo should not fail: \(error)")
            }
        },

        TestCase("A refusal is reported, not thrown away") { t in
            // The updater decides whether to install by reading these: a
            // non-zero status that arrived as an exception, or as a zero, is a
            // signature check that says yes to everything.
            do {
                let result = try Command.run("/bin/sh", ["-c", "exit 3"], deadline: 10)
                t.expectEqual(result.status, 3, "status")
                t.expect(!result.succeeded, "did not succeed")
            } catch {
                t.fail("a non-zero exit is an answer, not an error: \(error)")
            }
        },

        TestCase("Standard error is kept, because that is where the reason is") { t in
            do {
                let result = try Command.run(
                    "/bin/sh", ["-c", "echo why >&2; exit 1"], deadline: 10
                )
                t.expect(result.output.contains("why"), "the reason survived")
            } catch {
                t.fail("unexpected: \(error)")
            }
        },

        TestCase("Where the output is parsed, standard error can be left out") { t in
            // The focus path reads `tmux list-panes`, `lsof` and `ssh -G` as
            // records. A warning printed on the error stream would arrive
            // interleaved with them and be parsed as one, which is why those
            // three callers ask for stdout alone.
            do {
                let merged = try Command.run(
                    "/bin/sh", ["-c", "echo out; echo noise >&2"], deadline: 10
                )
                t.expect(merged.output.contains("noise"), "merged by default")

                let clean = try Command.run(
                    "/bin/sh", ["-c", "echo out; echo noise >&2"],
                    deadline: 10, capturingStandardError: false
                )
                t.expectEqual(clean.output, "out\n", "only what was parsed")
            } catch {
                t.fail("unexpected: \(error)")
            }
        },

        TestCase("A tool that hangs is killed at the deadline") { t in
            let started = Date()
            t.expectThrows(Command.Failure.timedOut(tool: "/bin/sleep", seconds: 1)) {
                _ = try Command.run("/bin/sleep", ["30"], deadline: 1)
            }
            // The point is not only that it throws, but that it comes back: a
            // deadline that fires after the tool finishes anyway is decoration.
            t.expect(Date().timeIntervalSince(started) < 5, "returned promptly")
        },

        TestCase("More output than a pipe can hold does not deadlock") { t in
            // A pipe holds about 64 KB. The three-line version of this function
            // waits for the process before reading, so the tool blocks writing
            // and the caller blocks waiting, and neither is broken and neither
            // moves. Two hundred kilobytes is comfortably past that.
            let size = 200_000
            do {
                let result = try Command.run(
                    "/bin/sh", ["-c", "/usr/bin/head -c \(size) /dev/zero | /usr/bin/tr '\\0' 'x'"],
                    deadline: 20
                )
                t.expectEqual(result.status, 0, "status")
                t.expectEqual(result.output.count, size, "every byte arrived")
            } catch {
                t.fail("a talkative tool should still finish: \(error)")
            }
        },

        TestCase("Input goes in on standard input, past what a pipe holds") { t in
            let input = String(repeating: "frame ", count: 40_000)
            do {
                let result = try Command.run("/bin/cat", deadline: 20, input: Data(input.utf8))
                t.expectEqual(result.output.count, input.count, "every byte came back")
            } catch {
                t.fail("cat should echo its input: \(error)")
            }
        },

        TestCase("A tool that never reads its input does not take the caller down") { t in
            // Writing into a pipe whose reader has gone raises SIGPIPE, which ends
            // the writer: here, the panel.
            let input = Data(repeating: 0x61, count: 300_000)
            do {
                let result = try Command.run("/usr/bin/true", deadline: 20, input: input)
                t.expectEqual(result.status, 0, "status")
            } catch {
                t.fail("true should succeed: \(error)")
            }
        },

        TestCase("The tool runs in the directory it is given") { t in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("command-directory-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try? Command.run("/bin/pwd", ["-P"], deadline: 10, directory: directory)
            t.expect(result?.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix(directory.lastPathComponent) == true, "pwd names the directory")
        },

        TestCase("A tool that is not there is refused straight away") { t in
            do {
                _ = try Command.run("/usr/bin/no-such-tool-exists-here", deadline: 10)
                t.fail("a missing tool should not report success")
            } catch let failure as Command.Failure {
                switch failure {
                case .couldNotStart(let tool, _):
                    t.expect(tool.hasSuffix("no-such-tool-exists-here"), "names the tool")
                case .timedOut:
                    t.fail("waited for a tool that was never going to start")
                }
            } catch {
                t.fail("unexpected error: \(error)")
            }
        },
    ])
}
