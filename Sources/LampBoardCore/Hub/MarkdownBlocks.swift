import Foundation

/// A Markdown file cut into the blocks the Hub's preview draws (D156): headings,
/// paragraphs, lists, quotes, fenced code, tables and rules. Inline marks stay in
/// the text, for the drawing to read. Pure and quick: a README of a hundred
/// kilobytes is parsed away from the main thread, once per file.
public enum MarkdownBlocks {

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String, text: String)
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, number: String, text: String)
        case quote(String)
        /// The header row first.
        case table(rows: [[String]])
        case rule
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence runs to its closing fence (a bare run of the same mark, at
            // least as long), or to the end; one under a list item too.
            if let fence = fence(trimmed) {
                flush()
                var body: [String] = []
                index += 1
                while index < lines.count, !closes(lines[index].trimmingCharacters(in: .whitespaces), fence.marker) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.isEmpty { flush(); index += 1; continue }

            // A line of = or - under a paragraph makes it a heading.
            if !paragraph.isEmpty, quote.isEmpty, isUnderline(trimmed) {
                let text = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: text))
                index += 1
                continue
            }

            if let heading = heading(trimmed) { flush(); blocks.append(heading); index += 1; continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); index += 1; continue }

            if index + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[index + 1]) {
                flush()
                var rows = [cells(trimmed)]
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(cells(row))
                    index += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
                var rest = trimmed.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                quote.append(String(rest))
                index += 1
                continue
            }

            if let item = listItem(line) {
                flush()
                blocks.append(item)
                index += 1
                // Lines indented under an item, up to a blank line, are the item's.
                while index < lines.count, leadingSpaces(lines[index]) >= 2,
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, listItem(lines[index]) == nil,
                      fence(lines[index].trimmingCharacters(in: .whitespaces)) == nil {
                    blocks[blocks.count - 1] = extended(blocks[blocks.count - 1], with: lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                continue
            }

            if !quote.isEmpty { flush() }
            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return blocks
    }

    // MARK: - Lines

    private static func fence(_ trimmed: String) -> (marker: String, language: String)? {
        for mark in ["`", "~"] where trimmed.hasPrefix(mark + mark + mark) {
            let run = trimmed.prefix(while: { String($0) == mark })
            let language = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            return (String(run), String(language.split(separator: " ").first ?? ""))
        }
        return nil
    }

    private static func closes(_ trimmed: String, _ marker: String) -> Bool {
        guard let mark = marker.first, trimmed.first == mark else { return false }
        return trimmed.count >= marker.count && trimmed.allSatisfy { $0 == mark }
    }

    private static func heading(_ trimmed: String) -> Block? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s is not part of the heading, when a space comes
        // before it: "C#" keeps its sharp.
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let before = text.dropLast(closing)
            if before.isEmpty || before.last == " " { text = String(before) }
        }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isUnderline(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.contains("-"), stripped.contains("|") || stripped.hasPrefix(":") || stripped.hasPrefix("-") else { return false }
        return stripped.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" } && stripped.contains("|")
    }

    private static func cells(_ row: String) -> [String] {
        var content = Substring(row)
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|") { content = content.dropLast() }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> Block? {
        let depth = min(leadingSpaces(line) / 2, 4)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().hasPrefix(" ") {
            return .bullet(depth: depth, text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().hasPrefix(" ") else { return nil }
        return .numbered(depth: depth, number: String(digits), text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func extended(_ block: Block, with line: String) -> Block {
        switch block {
        case .bullet(let depth, let text): return .bullet(depth: depth, text: text + " " + line)
        case .numbered(let depth, let number, let text): return .numbered(depth: depth, number: number, text: text + " " + line)
        default: return block
        }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }
}
