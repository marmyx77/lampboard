import Foundation

/// What may go into a terminal as a paste, on the Mac's live view and on a
/// phone's terminal alike (H1.2-10): a citation, a mention, a dropped file's
/// path, text from the clipboard.
///
/// Inside the bracketed-paste marks the text cannot end the paste early: the
/// marks themselves and every control character but a tab or a line break are
/// taken out. Without the marks (a program that did not ask for them) a line
/// break would be an Enter, so it becomes a space: nothing pasted is ever sent.
public enum LiveSurfaceText {

    public static func forPaste(_ text: String) -> String {
        let unmarked = text.replacingOccurrences(of: "\u{1b}[200~", with: "").replacingOccurrences(of: "\u{1b}[201~", with: "")
        return String(unmarked.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || !(scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value))
        }.map(Character.init))
    }

    /// The bytes a paste of `text` sends, marked when the terminal asked for
    /// bracketed paste.
    public static func bytes(_ text: String, bracketed: Bool) -> [UInt8] {
        let cleaned = forPaste(text)
        guard bracketed else {
            return Array(cleaned.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").utf8)
        }
        return Array("\u{1b}[200~".utf8) + Array(cleaned.utf8) + Array("\u{1b}[201~".utf8)
    }
}
