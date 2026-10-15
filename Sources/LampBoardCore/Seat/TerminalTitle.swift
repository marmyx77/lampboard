import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Setting a terminal's title by writing to the tty a session runs on.
///
/// This exists for the one fact Ghostty's dictionary will not give up. It lists
/// a surface's id, its title and its folder, and on a real machine none of the
/// three tells two conversations apart: two Codex sessions in
/// `~/Development/turing`, both titled `turing`, and a click could only ever
/// raise the first of them. Every other host answers this — Terminal.app and
/// iTerm2 expose the tty, WezTerm does, kitty matches on the pid — so Ghostty
/// was the only place where the panel had to guess, and a row that leads to the
/// wrong tab is worse than one that admits it does not know.
///
/// So the question is asked the other way round. The panel knows the tty and
/// Ghostty does not expose it; Ghostty knows the surface id and the panel cannot
/// derive it. Write a title nobody would choose to that tty, ask which surface
/// now carries it, put the old one back. The surface that changed **is** the
/// surface on that tty — a measurement, not a plausible guess.
///
/// Writing to a slave pty is a **display, never an input**: the bytes travel to
/// the emulator holding the master, which is how `wall` and `write(1)` have
/// always worked. Nothing is typed into the program running there, and the
/// sequence itself prints nothing.
public enum TerminalTitle {

    /// What a probe title starts with. Long and dull on purpose: it has to be a
    /// string no shell, editor or agent would ever set by itself.
    public static let markerPrefix = "lampboard-probe-"

    /// A probe title for one attempt.
    ///
    /// A fresh nonce every time rather than a fixed string, because two probes
    /// can overlap — a click while an earlier one is still settling — and a
    /// shared marker would let the second read the first one's answer.
    public static func randomMarker() -> String {
        markerPrefix + String(UInt64.random(in: 0..<0xFFFF_FFFF_FFFF), radix: 16)
    }

    public static func isMarker(_ title: String) -> Bool {
        title.hasPrefix(markerPrefix)
    }

    /// The escape sequence that sets a title: `OSC 0 ; text BEL`.
    public static func sequence(setting title: String) -> String {
        "\u{1B}]0;\(sanitized(title))\u{07}"
    }

    /// A title with everything that could escape it taken out.
    ///
    /// Not defensive decoration. The string written back at the end of a probe
    /// came **out** of the terminal, and a program is free to put anything in
    /// its own title; writing it home unexamined would run whatever sequence it
    /// carries inside a terminal the user is working in. Control characters go,
    /// and the length is bounded, because a title is a label and not a payload.
    public static func sanitized(_ title: String) -> String {
        let printable = title.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(printable).prefix(256))
    }

    /// Writes the title to that tty. `false` when it could not be written at
    /// all, which the caller must read as "ask something else", never as an
    /// answer.
    ///
    /// Refuses any path that is not a tty: the path comes from the process
    /// table, and a guard on the one shape it may have costs nothing next to
    /// what an unguarded `open` for writing could be pointed at. `O_NOCTTY` so
    /// the panel never picks up a controlling terminal on the way, and
    /// `O_NONBLOCK` because this runs on the thread that draws.
    @discardableResult
    public static func write(_ title: String, toTTY path: String) -> Bool {
        guard path.hasPrefix("/dev/tty"), !path.contains("..") else { return false }
        let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let bytes = Array(sequence(setting: title).utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            systemWrite(descriptor, buffer.baseAddress, buffer.count) == buffer.count
        }
    }

    /// The C library's `write`, named by its module: inside this type the bare
    /// name is the method above. Darwin on the Mac and on iOS, glibc on Linux,
    /// musl in a static Linux build.
    private static func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, bytes, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, bytes, count)
        #else
        return Musl.write(descriptor, bytes, count)
        #endif
    }
}
