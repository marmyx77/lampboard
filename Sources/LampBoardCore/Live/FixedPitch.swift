import Foundation

/// Whether a font draws every character at one width (D145), measured rather
/// than taken from the font's own flag: iA Writer Mono, among others, is
/// fixed-width and does not say so, and was missing from the list.
public enum FixedPitch {

    /// The characters measured: a narrow one, a wide one, a round one, a dot.
    public static let probe = ["i", "W", "m", "."]

    /// The widths of `probe` in one font: all equal, and not zero.
    public static func isUniform(_ widths: [Double]) -> Bool {
        guard let first = widths.first, first > 0, widths.count == probe.count else { return false }
        return widths.allSatisfy { abs($0 - first) < 0.01 }
    }
}
