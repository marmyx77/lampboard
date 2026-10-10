import Foundation
import LampBoardCore
import TestKit

/// The Hub's Markdown preview (D156): a file cut into the blocks it draws,
/// away from the main thread, so a README of a hundred kilobytes is drawn once
/// and never measured again on every change (10 October 2026).
enum MarkdownBlocksSuite {

    static let suite = TestSuite("The Hub's Markdown blocks", [

        TestCase("Headings, paragraphs joined, rules and setext headings") { t in
            let blocks = MarkdownBlocks.parse("# Title #\n\nOne line\nand its next.\n\n---\n\nUnder\n===\n\nAlso\n---\n####### not a heading")
            t.expectEqual(blocks, [
                .heading(level: 1, text: "Title"),
                .paragraph("One line and its next."),
                .rule,
                .heading(level: 1, text: "Under"),
                .heading(level: 2, text: "Also"),
                .paragraph("####### not a heading"),
            ])
        },

        TestCase("A fence keeps its lines as written, and an open one runs to the end") { t in
            let blocks = MarkdownBlocks.parse("```swift title\nlet a = 1\n\n# not a heading\n```\nafter\n~~~\nopen")
            t.expectEqual(blocks, [
                .code(language: "swift", text: "let a = 1\n\n# not a heading"),
                .paragraph("after"),
                .code(language: "", text: "open"),
            ])
        },

        TestCase("Lists keep their depth and number, and lines indented under an item are its own") { t in
            let blocks = MarkdownBlocks.parse("- one\n  still one\n  - inner\n* two\n3. three\n10) ten")
            t.expectEqual(blocks, [
                .bullet(depth: 0, text: "one still one"),
                .bullet(depth: 1, text: "inner"),
                .bullet(depth: 0, text: "two"),
                .numbered(depth: 0, number: "3", text: "three"),
                .numbered(depth: 0, number: "10", text: "ten"),
            ])
        },

        TestCase("Quotes run together; tables need their separator line") { t in
            let blocks = MarkdownBlocks.parse("> a\n> b\n\n| A | B |\n|---|:-:|\n| 1 | 2 |\n\n| not | a table |\nplain")
            t.expectEqual(blocks, [
                .quote("a\nb"),
                .table(rows: [["A", "B"], ["1", "2"]]),
                .paragraph("| not | a table | plain"),
            ])
        },

        TestCase("A sharp stays in a heading; a fence under an item, and a longer fence around a shorter one, keep their lines") { t in
            t.expectEqual(MarkdownBlocks.parse("## C#\n# Learn F# #"), [.heading(level: 2, text: "C#"), .heading(level: 1, text: "Learn F#")])
            t.expectEqual(MarkdownBlocks.parse("- item\n\n    ```sh\n    a\n    b\n    ```"), [
                .bullet(depth: 0, text: "item"),
                .code(language: "sh", text: "    a\n    b"),
            ])
            t.expectEqual(MarkdownBlocks.parse("````md\n```swift\nlet a = 1\n```\n````\nafter"), [
                .code(language: "md", text: "```swift\nlet a = 1\n```"),
                .paragraph("after"),
            ])
        },

        TestCase("A README of a hundred kilobytes is parsed in well under a second") { t in
            let part = "## Part\n\nWords that go on. Words that go on.\n\n- a\n- b\n\n```sh\necho hi\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n"
            let text = String(repeating: part, count: 1000)
            let start = Date()
            let blocks = MarkdownBlocks.parse(text)
            t.expectEqual(blocks.count, 6000)
            t.expect(Date().timeIntervalSince(start) < 1, "parsed in \(Date().timeIntervalSince(start)) s")
        },
    ])
}
