import AppKit
import LampBoardCore
import SwiftTerm

/// One command running in a terminal view (D130).
///
/// The rest of the app sees an `NSView` and a few verbs, never a SwiftTerm type:
/// the emulator stays behind this file, so it can be replaced (libghostty, one
/// day) without touching the window around it. Relay keeps the same rule.
@MainActor
protocol LiveSurface: AnyObject {
    var view: NSView { get }
    /// The child's pid, `0` before it started.
    var pid: pid_t { get }
    var isRunning: Bool { get }
    /// The child ended, by itself or because `end()` was called.
    var onExit: ((Int32?) -> Void)? { get set }
    func start(_ command: LiveCommand)
    /// Text as a paste: wrapped in bracketed-paste marks when the program asked
    /// for them, so Claude Code takes `@path` as typed text and never as Enter.
    func paste(_ text: String)
    func apply(theme: LiveTheme, fontSize: Double)
    /// What the screen shows now, as plain text: the last `lines` of it.
    func screenText(lines: Int) -> String
    /// Whether the program asked for bracketed paste: until it has, a paste
    /// would be typed, and a citation waits for it.
    var acceptsPaste: Bool { get }
    /// Still running as the process that was started, pid and start time alike.
    var isStillOurs: Bool { get }
    /// Ends the child and its process group; idempotent. `waiting` holds the
    /// caller until it is gone, as quitting must: nothing escalates after exit.
    func end(waiting: Bool)
}

/// The SwiftTerm implementation.
@MainActor
final class SwiftTermSurface: NSObject, LiveSurface, LocalProcessTerminalViewDelegate {

    private let terminal: LocalProcessTerminalView
    private var ended = false
    /// The child's pid and start time, kept from the moment it ran: a pid is
    /// reused by the system, and only the pair says it is still ours.
    private var child: (pid: pid_t, startedAt: Double)?
    private var exited = false
    var onExit: ((Int32?) -> Void)?

    override init() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminal.processDelegate = self
        // Option types characters, as it does everywhere else on a Mac: on an
        // Italian keyboard @ and # are Option keys, and `@path` is how a file is
        // named to Claude Code. As Meta it would send escape sequences instead.
        terminal.optionAsMetaKey = false
    }

    var view: NSView { terminal }
    var pid: pid_t { terminal.process?.shellPid ?? 0 }
    var isRunning: Bool { terminal.process?.running ?? false }

    func start(_ command: LiveCommand) {
        let environment = command.environment.map { "\($0.key)=\($0.value)" }.sorted()
        terminal.startProcess(executable: command.executable, args: command.arguments,
                              environment: environment, execName: nil, currentDirectory: command.directory)
        let started = pid
        if started > 1, let at = LiveProcesses.startTime(of: started) { child = (started, at) }
    }

    var acceptsPaste: Bool { isRunning && terminal.getTerminal().bracketedPasteMode }

    /// Inside the marks, the text cannot end the paste early: the marks
    /// themselves and every control character but a tab or a line break are
    /// taken out. Without the marks a line break would be an Enter, so it
    /// becomes a space.
    func paste(_ text: String) {
        guard isRunning else { return }
        let cleaned = LiveSurfaceText.forPaste(text)
        if terminal.getTerminal().bracketedPasteMode {
            terminal.send(Array("\u{1b}[200~".utf8) + Array(cleaned.utf8) + Array("\u{1b}[201~".utf8))
        } else {
            terminal.send(txt: cleaned.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
        }
    }

    func apply(theme: LiveTheme, fontSize: Double) {
        terminal.font = NSFont.monospacedSystemFont(ofSize: LiveTheme.clampedFontSize(fontSize), weight: .regular)
        terminal.nativeBackgroundColor = NSColor(liveHex: theme.card)
        terminal.nativeForegroundColor = NSColor(liveHex: theme.text)
        terminal.caretColor = NSColor(liveHex: theme.text)
    }

    func screenText(lines: Int) -> String {
        let text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces) }
        let used = rows.reversed().drop { $0.isEmpty }.reversed()
        return used.suffix(lines).joined(separator: "\n")
    }

    /// SIGHUP to the whole process group, as closing a terminal does: `claude
    /// attach` detaches on it and the background session goes on. A child that
    /// ignores it gets SIGTERM after a second and SIGKILL after three, because
    /// SwiftTerm's own `terminate()` only closes the pty and can leave it running.
    func end(waiting: Bool) {
        guard !ended else { return }
        ended = true
        terminal.terminate()
        // An attach that already ended was reaped: its pid may be a stranger's now.
        guard !exited, let child else { return }
        if waiting { LiveSignals.hangUpAndWait(child.pid, startedAt: child.startedAt) }
        else { LiveSignals.hangUp(child.pid, startedAt: child.startedAt) }
    }

    /// Still running as the process that was started.
    var isStillOurs: Bool {
        guard let child else { return false }
        return LiveSignals.isSame(child.pid, startedAt: child.startedAt)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.exited = true
            self?.onExit?(exitCode)
        }
    }
}

/// What may go into a paste.
enum LiveSurfaceText {
    static func forPaste(_ text: String) -> String {
        let unmarked = text.replacingOccurrences(of: "\u{1b}[200~", with: "").replacingOccurrences(of: "\u{1b}[201~", with: "")
        return String(unmarked.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || !(scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value))
        }.map(Character.init))
    }
}

/// Ending a process group the way a closed terminal does, then less politely.
///
/// Every signal is preceded by the same question: is this pid still the process
/// that was started at that time? A pid freed by an exit is handed out again, and
/// a group signal to a stranger's pid would reach a whole group of the person's
/// own programs. A pid of 0 or 1 is never signalled at all.
enum LiveSignals {
    static func isSame(_ pid: pid_t, startedAt: Double) -> Bool {
        guard pid > 1, let now = LiveProcesses.startTime(of: pid) else { return false }
        return abs(now - startedAt) < 1
    }

    private static func send(_ signal: Int32, to pid: pid_t, startedAt: Double) {
        guard isSame(pid, startedAt: startedAt) else { return }
        _ = kill(-pid, signal)
        _ = kill(pid, signal)
    }

    /// SIGHUP now, SIGTERM after a second, SIGKILL after three; off the main thread.
    static func hangUp(_ pid: pid_t, startedAt: Double) {
        send(SIGHUP, to: pid, startedAt: startedAt)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            send(SIGTERM, to: pid, startedAt: startedAt)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                send(SIGKILL, to: pid, startedAt: startedAt)
            }
        }
    }

    /// The same, waited for, in under a second: what quitting does, since a
    /// timer set now would never fire after the app is gone.
    static func hangUpAndWait(_ pid: pid_t, startedAt: Double) {
        for (signal, grace) in [(SIGHUP, 0.4), (SIGTERM, 0.3), (SIGKILL, 0.1)] {
            send(signal, to: pid, startedAt: startedAt)
            let deadline = Date().addingTimeInterval(grace)
            while isSame(pid, startedAt: startedAt), Date() < deadline { usleep(20_000) }
            if !isSame(pid, startedAt: startedAt) { return }
        }
    }
}

extension NSColor {
    /// `#rrggbb` from a theme; black for anything else, which a test forbids.
    convenience init(liveHex hex: String) {
        let (r, g, b) = LiveTheme.rgb(hex) ?? (0, 0, 0)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
