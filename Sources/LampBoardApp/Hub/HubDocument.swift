import AppKit
import ClarcChatKit
import LampBoardCore
import SwiftUI

/// A file of the project as the last column shows it (D156), made once, away
/// from the main thread, and drawn by an AppKit text view.
///
/// Before (10 October 2026) the file was a SwiftUI `Text`: a README of 100 KB
/// was measured several times on every layout pass, and highlighted again on
/// every change of the Hub, a keystroke in the composer included. The main
/// thread stayed held for tens of seconds, and the windows stopped coming up.
/// A text view lays out once per width, and only the part in sight.
final class HubDocument: @unchecked Sendable, Equatable {

    let text: NSAttributedString
    /// Where each line starts, for the numbers in the margin (code only).
    let lineStarts: [Int]
    let numbered: Bool
    /// Whether lines are wrapped: always for prose, and for code with a line
    /// too long to scroll to (a minified file is one line of a megabyte).
    let wraps: Bool

    /// The longest line kept whole; past it, code wraps.
    static let longestUnwrapped = 2000

    private init(text: NSAttributedString, numbered: Bool) {
        self.text = text
        self.numbered = numbered
        guard numbered else { lineStarts = []; wraps = true; return }
        var starts = [0]
        var longest = 0
        var offset = 0
        for unit in text.string.utf16 {
            offset += 1
            if unit == 0x0A {
                longest = max(longest, offset - starts[starts.count - 1])
                starts.append(offset)
            }
        }
        longest = max(longest, offset - starts[starts.count - 1])
        lineStarts = starts
        wraps = longest > Self.longestUnwrapped
    }

    static func == (a: HubDocument, b: HubDocument) -> Bool { a === b }

    // MARK: - Making

    /// Past this, the code is drawn plain: tokenizing a generated megabyte
    /// would take seconds for colours no one reads.
    static let mostHighlighted = 300_000

    static func code(_ source: String, language: String) -> HubDocument {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text: NSMutableAttributedString
        if source.utf16.count <= mostHighlighted {
            text = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlightNS(source, language: language, fontSize: 12))
        } else {
            text = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: Ink.text])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.1
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return HubDocument(text: text, numbered: true)
    }

    static func markdown(_ source: String) -> HubDocument {
        let out = NSMutableAttributedString()
        for block in MarkdownBlocks.parse(source) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(render(block))
        }
        return HubDocument(text: out, numbered: false)
    }

    // MARK: - Markdown's blocks

    private static func render(_ block: MarkdownBlocks.Block) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [22, 18, 15.5, 14, 13, 13]
            let line = inline(text, size: sizes[min(level, 6) - 1], weight: .bold)
            line.addAttribute(.paragraphStyle, value: style(before: level <= 2 ? 14 : 10, after: 4), range: whole(line))
            return line
        case .paragraph(let text):
            let line = inline(text)
            line.addAttribute(.paragraphStyle, value: style(after: 6), range: whole(line))
            return line
        case .bullet(let depth, let text):
            return item("•", depth: depth, text: text)
        case .numbered(let depth, let number, let text):
            return item(number + ".", depth: depth, text: text)
        case .quote(let text):
            let line = inline(text, color: Ink.muted)
            spaced(line, indent: 14, after: 6)
            return line
        case .code(let language, let text):
            let line = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlightNS(text.isEmpty ? " " : text, language: language, fontSize: 12))
            line.addAttribute(.backgroundColor, value: Ink.codeBackground, range: whole(line))
            spaced(line, indent: 10, after: 8)
            return line
        case .table(let rows):
            return table(rows)
        case .rule:
            let line = NSMutableAttributedString(string: String(repeating: "─", count: 40),
                                                 attributes: [.foregroundColor: Ink.line, .font: NSFont.systemFont(ofSize: 10)])
            line.addAttribute(.paragraphStyle, value: style(before: 6, after: 6), range: whole(line))
            return line
        }
    }

    private static func item(_ mark: String, depth: Int, text: String) -> NSAttributedString {
        let indent = CGFloat(depth) * 18
        let line = NSMutableAttributedString(string: mark + "\t", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Ink.muted])
        line.append(inline(text))
        let paragraph = style(indent: indent, after: 3)
        paragraph.headIndent = indent + 18
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
        line.addAttribute(.paragraphStyle, value: paragraph, range: whole(line))
        return line
    }

    /// A table in columns of fixed width: read, not laid out.
    private static func table(_ rows: [[String]]) -> NSAttributedString {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in min(40, rows.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0) }
        let out = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let cells = (0..<columns).map { column -> String in
                let cell = row.indices.contains(column) ? String(row[column].prefix(40)) : ""
                return cell + String(repeating: " ", count: max(0, widths[column] - cell.count))
            }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: index == 0 ? .semibold : .regular)
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: cells.joined(separator: "  │  "), attributes: [.font: font, .foregroundColor: Ink.text]))
            if index == 0 {
                let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "──┼──")
                out.append(NSAttributedString(string: "\n" + rule, attributes: [.font: font, .foregroundColor: Ink.line]))
            }
        }
        spaced(out, after: 8)
        return out
    }

    /// A block of several lines: its lines close together, the space after
    /// its last one only (every line of a block is a paragraph of its own).
    private static func spaced(_ text: NSMutableAttributedString, indent: CGFloat = 0, after: CGFloat) {
        text.addAttribute(.paragraphStyle, value: style(indent: indent), range: whole(text))
        let last = (text.string as NSString).range(of: "\n", options: .backwards)
        let start = last.location == NSNotFound ? 0 : last.location + 1
        text.addAttribute(.paragraphStyle, value: style(indent: indent, after: after),
                          range: NSRange(location: start, length: text.length - start))
    }

    /// Bold, italics, code and links inside a line, read by Foundation's parser.
    private static func inline(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                               color: NSColor = Ink.text) -> NSMutableAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSMutableAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                attributes[.backgroundColor] = Ink.codeBackground
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) || weight == .bold { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
                    attributes[.font] = NSFont(descriptor: descriptor, size: size) ?? base
                }
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Only the web opens from a preview: a file's text can carry any scheme.
            if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
                attributes[.foregroundColor] = Ink.link
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    private static func style(before: CGFloat = 0, indent: CGFloat = 0, after: CGFloat = 0) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineHeightMultiple = 1.15
        return paragraph
    }

    private static func whole(_ text: NSAttributedString) -> NSRange { NSRange(location: 0, length: text.length) }

    /// The Hub's colours (HubPalette), as AppKit takes them off the main thread.
    enum Ink {
        static let text = NSColor(srgbRed: 0xE4 / 255, green: 0xE8 / 255, blue: 0xEB / 255, alpha: 1)
        static let muted = NSColor(srgbRed: 0x9A / 255, green: 0xA5 / 255, blue: 0xAE / 255, alpha: 1)
        static let line = NSColor(srgbRed: 0x4A / 255, green: 0x55 / 255, blue: 0x5E / 255, alpha: 1)
        static let link = NSColor(srgbRed: 0x7F / 255, green: 0xB0 / 255, blue: 0xDE / 255, alpha: 1)
        static let codeBackground = NSColor(srgbRed: 0x25 / 255, green: 0x2C / 255, blue: 0x32 / 255, alpha: 1)
        static let panel = NSColor(srgbRed: 0x1C / 255, green: 0x22 / 255, blue: 0x27 / 255, alpha: 1)
    }
}

// MARK: - Drawing

/// The text view that shows a `HubDocument`: read only, selectable, lines
/// numbered in a margin of its own for code, wrapped for prose and kept whole
/// for code.
struct HubDocumentView: NSViewRepresentable {
    let document: HubDocument
    /// What is shown (the file and its mode): the same place read again keeps
    /// where the person was reading, while the session writes the file.
    let place: String

    final class Coordinator { var shown: HubDocument?; var place: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = HubDocumentScroll()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = HubDocument.Ink.panel
        // TextKit 1 on purpose: its layout skips what is out of sight, and the
        // margin's numbers read its line fragments.
        let text = HubCodeTextView(usingTextLayoutManager: false)
        // Born with a size: a text view of zero width laid out nothing it could draw.
        text.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityIdentifier("hub.viewer.text")
        scroll.documentView = text
        return scroll
    }

    /// The column's room, whatever the text's width: asked its own size, a
    /// scroll view answers with its document's, and a line of code a thousand
    /// points wide pushed the tabs and the text out of the column.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        func room(_ length: CGFloat?) -> CGFloat { length.map { $0.isFinite ? $0 : 300 } ?? 300 }
        return CGSize(width: room(proposal.width), height: room(proposal.height))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shown !== document, let text = scroll.documentView as? HubCodeTextView,
              let container = text.textContainer else { return }
        let samePlace = context.coordinator.place == place
        let origin = scroll.contentView.bounds.origin
        let selection = text.selectedRanges
        context.coordinator.shown = document
        context.coordinator.place = place
        text.lineStarts = document.numbered ? document.lineStarts : []
        (scroll as? HubDocumentScroll)?.wraps = document.wraps
        if document.wraps {
            text.isHorizontallyResizable = false
            text.frame.size.width = max(scroll.contentSize.width, 100)
            container.widthTracksTextView = true
            // Said outright: a container left infinitely wide by code never wraps.
            container.containerSize = NSSize(width: max(text.frame.width - 2 * text.textContainerInset.width, 50),
                                             height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = false
        } else {
            // Code keeps its lines whole: wide lines scroll sideways.
            text.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
        }
        text.textStorage?.setAttributedString(document.text)
        if samePlace {
            let length = (text.string as NSString).length
            let kept = selection.map(\.rangeValue).filter { NSMaxRange($0) <= length }
            if !kept.isEmpty { text.selectedRanges = kept.map { NSValue(range: $0) } }
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            text.scroll(.zero)
        }
        HubCodeTextView.shown = text
    }
}

/// The scroll view that keeps wrapped text as wide as what is in sight: a
/// text view's width follows its column only by the difference, and one born
/// wider than the column stayed wider, its lines cut at the right edge.
final class HubDocumentScroll: NSScrollView {
    var wraps = true { didSet { needsLayout = true } }

    override func tile() {
        super.tile()
        guard wraps, let text = documentView, text.frame.width != contentSize.width else { return }
        text.frame.size.width = contentSize.width
    }
}

/// A text view with the line numbers in a margin of its own, at the left of
/// what is in sight. AppKit's ruler was tried first: since macOS 14 it floats
/// over the content, and it covered the code and the tabs.
final class HubCodeTextView: NSTextView {

    /// The last one shown, for the tests' report of what is drawn.
    @MainActor static weak var shown: HubCodeTextView?

    /// What a test can check of the drawing: text there, in sight, inside its
    /// window, as wide as its column when it wraps (10 October 2026: each of
    /// these failed once while the Hub's numbers looked fine).
    var drawn: [String: Any] {
        guard let scroll = enclosingScrollView, let window, let layout = layoutManager, let container = textContainer else {
            return ["inWindow": false]
        }
        let inWindow = scroll.convert(scroll.bounds, to: nil)
        let content = window.contentView?.bounds ?? .zero
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        return [
            "inWindow": content.contains(inWindow.insetBy(dx: 1, dy: 1)),
            "chars": (string as NSString).length,
            "glyphsInSight": glyphs.length,
            "wraps": !isHorizontallyResizable,
            "textWidth": Int(frame.width),
            "columnWidth": Int(scroll.contentSize.width),
            "margin": Int(origin.x),
        ]
    }

    /// Where each line starts; empty for prose, which has no numbers.
    var lineStarts: [Int] = [] {
        didSet {
            // Inset on both sides by half the margin and moved right by all of
            // it: the frame's width takes the margin in, the code starts after it.
            textContainerInset = NSSize(width: margin / 2 + 10, height: 10)
            needsDisplay = true
        }
    }

    private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private var margin: CGFloat {
        guard !lineStarts.isEmpty else { return 0 }
        return CGFloat(max(String(lineStarts.count).count, 2)) * 7.5 + 14
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: textContainerInset.width * 2 - 10, y: origin.y)
    }

    /// Under the text, which leaves the margin empty: drawn over it, the
    /// numbers never reached the screen (macOS 14 composes the text apart).
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard !lineStarts.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        // At the document's left edge: drawn under the text, they scroll
        // sideways with the code rather than be painted over by it.
        let strip = NSRect(x: 0, y: dirtyRect.minY, width: margin, height: dirtyRect.height)
        HubDocument.Ink.panel.setFill()
        strip.fill()
        let origin = textContainerOrigin
        // The lines across the dirty rect's height, whatever part of the width it is.
        let band = NSRect(x: 0, y: dirtyRect.minY - origin.y, width: min(max(container.size.width, 1), 10_000_000), height: dirtyRect.height)
        let glyphs = layout.glyphRange(forBoundingRect: band, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (string as NSString).length
        // The first line in the dirty rect: the last start at or before its first character.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= characters.location { low = middle } else { high = middle - 1 }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: HubDocument.Ink.muted]
        var line = low
        while line < lineStarts.count, lineStarts[line] < NSMaxRange(characters), lineStarts[line] < length {
            let glyph = layout.glyphIndexForCharacter(at: lineStarts[line])
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            line += 1
            guard !fragment.isEmpty else { continue }
            let label = NSAttributedString(string: String(line), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: margin - size.width - 6,
                                   y: fragment.minY + origin.y + (fragment.height - size.height) / 2))
        }
    }
}
