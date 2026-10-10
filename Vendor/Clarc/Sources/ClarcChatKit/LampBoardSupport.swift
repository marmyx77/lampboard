// Partly from Clarc (https://github.com/ttnear/Clarc), Apache License 2.0:
// `ToolCategory`, `PreviewFile`, `stripCommonIndent` and the line decoder's
// dates are Clarc's code, copied; the stand-ins around them are LampBoard's.
// See Vendor/Clarc/VENDORED.md.

import Foundation
import SwiftUI

// LampBoard's stand-ins for the parts of Clarc's app the vendored views reach
// for (Vendored patch 1 in ../../VENDORED.md). `ToolCategory` and `PreviewFile`
// are Clarc's own, copied whole; `WindowState`, `ChatBridge` and
// `InteractiveTerminalState` keep only the members these views use, and
// LampBoard decides what they do.

public enum ToolCategory: Sendable {
    case readOnly
    case fileModification
    case execution
    case mcp
    case unknown

    public init(toolName: String) {
        switch toolName.lowercased() {
        case "read", "glob", "grep", "list", "search":
            self = .readOnly
        case "edit", "write", "multiedit", "multi_edit":
            self = .fileModification
        case "bash", "execute":
            self = .execution
        default:
            if toolName.lowercased().hasPrefix("mcp__") {
                self = .mcp
            } else {
                self = .unknown
            }
        }
    }

    public var isTransient: Bool {
        self == .readOnly || self == .execution
    }

    public var sfSymbol: String {
        switch self {
        case .readOnly: return "doc.text"
        case .fileModification: return "pencil"
        case .execution: return "terminal"
        case .mcp: return "puzzlepiece.extension"
        case .unknown: return "wrench.and.screwdriver"
        }
    }
}

public struct PreviewFile: Identifiable, Sendable {
    public struct EditHunk: Sendable, Equatable {
        public let oldString: String
        public let newString: String

        public init(oldString: String, newString: String) {
            self.oldString = oldString
            self.newString = newString
        }
    }

    public let id = UUID()
    public let path: String
    public let name: String
    public let editHunks: [EditHunk]

    public init(path: String, name: String, editHunks: [EditHunk] = []) {
        self.path = path
        self.name = name
        self.editHunks = editHunks
    }
}

public enum InteractiveTerminalState {
    public static let toolName = "interactive_terminal"
}

/// What a tool row asks the window to show: a file, or its diff.
@Observable
@MainActor
public final class WindowState {
    public var inspectorFile: PreviewFile?
    public var diffFile: PreviewFile?
    public init() {}
}

/// Forking and editing a message are Clarc's; LampBoard's chat has neither,
/// and the bubble's menu entries for them do nothing.
@Observable
@MainActor
public final class ChatBridge {
    public init() {}
    public func forkFromHere(messageId: UUID) async {}
    public func editAndResend(messageId: UUID, newContent: String) async {}
}

/// Clarc's decoder for the CLI's lines, taken out of its session store (which
/// LampBoard does not take): ISO 8601 dates, with or without fractional
/// seconds, which Foundation's `.iso8601` alone refuses.
// Vendored patch 9: off the main actor, so a transcript is decoded away from it.
nonisolated public enum CLILineDecoder {
    public static func decode(_ lines: [String]) -> [CLISessionLine] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateStrategy
        return lines.compactMap { try? decoder.decode(CLISessionLine.self, from: Data($0.utf8)) }
    }

    private static let dateStrategy: JSONDecoder.DateDecodingStrategy = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = withFractional.date(from: s) { return d }
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
    }()
}

/// Clarc's, copied whole from `FileDiffView.swift`, which was left out: the
/// tool rows strip an edit's common indent with it.
nonisolated func stripCommonIndent(old: [String], new: [String]) -> (old: [String], new: [String]) {
    let combined = old + new
    let commonIndent = combined
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
        .min() ?? 0
    guard commonIndent > 0 else { return (old, new) }
    func strip(_ line: String) -> String {
        line.count >= commonIndent ? String(line.dropFirst(commonIndent)) : line
    }
    return (old.map(strip), new.map(strip))
}
