import AppKit
import LampBoardCore

/// The fonts a live window may use (D142, D145): the families on this Mac that
/// draw every character at one width, whether or not they say so. Claude Code
/// draws on a grid of cells, and a proportional font would pull its boxes and
/// columns apart.
enum LiveFonts {

    static func families() -> [String] {
        let manager = NSFontManager.shared
        let flagged = Set((manager.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .compactMap { NSFont(name: $0, size: 12)?.familyName })
        let measured = manager.availableFontFamilies.filter { !flagged.contains($0) && isFixedPitch($0) }
        // Hidden system families start with a dot.
        return flagged.union(measured).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func isFixedPitch(_ family: String) -> Bool {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        let widths = FixedPitch.probe.map { Double(($0 as NSString).size(withAttributes: [.font: font]).width) }
        return FixedPitch.isUniform(widths)
    }
}
