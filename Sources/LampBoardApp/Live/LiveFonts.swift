import AppKit

/// The fonts a live window may use (D142): the families on this Mac with a
/// fixed pitch. Claude Code draws on a grid of cells, and a proportional font
/// would pull its boxes and columns apart.
enum LiveFonts {

    static func families() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        // Hidden system families start with a dot.
        return families.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
