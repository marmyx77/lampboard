import Foundation

/// The rules of the Hub's command bar (D157), apart from its controls: what a
/// slash line is, which mode the footer shows and how many Shift+Tab reach
/// another, when a model change needs a warning, and an attachment's name.
public enum HubBar {

    // MARK: - Commands

    /// `/name args` when `name` is one of the session's commands, on one line;
    /// anything else is words for the model (a path starts with a slash too).
    public static func slash(_ text: String, known: Set<String>) -> (name: String, args: String)? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/"), !line.contains("\n") else { return nil }
        let body = line.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard known.contains(name) else { return nil }
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return (name, args)
    }

    // MARK: - Modes

    /// Claude Code's permission modes as its footer names them.
    public enum Mode: String, CaseIterable, Equatable, Sendable {
        case plan, auto, manual, acceptEdits, bypass

        /// What the bar's menu calls it.
        public var title: String {
            switch self {
            case .plan: return "Plan"
            case .auto: return "Auto"
            case .manual: return "Ask before edits"
            case .acceptEdits: return "Accept edits"
            case .bypass: return "Bypass permissions"
            }
        }
    }

    /// The order Shift+Tab goes round (measured with 2.1.296, P12).
    public static let cycle: [Mode] = [.plan, .auto, .manual, .acceptEdits]

    /// The mode the footer's label shows; none shown is the manual one.
    public static func mode(footer label: String) -> Mode {
        let text = label.lowercased()
        if text.contains("plan") { return .plan }
        if text.contains("auto") { return .auto }
        if text.contains("accept") { return .acceptEdits }
        if text.contains("bypass") { return .bypass }
        return .manual
    }

    /// How many Shift+Tab take `from` to `to`; `nil` when either is out of the
    /// cycle (bypass is chosen at launch, never pressed into).
    public static func presses(from: Mode, to: Mode) -> Int? {
        guard let a = cycle.firstIndex(of: from), let b = cycle.firstIndex(of: to) else { return nil }
        return (b - a + cycle.count) % cycle.count
    }

    // MARK: - Model

    /// The models the bar offers; the session's own default is the empty choice.
    public static let models: [(id: String, title: String)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
        ("claude-fable-5-1", "Fable 5.1"),
    ]

    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Whether the session's prompt cache is still alive: then another model
    /// reads the whole conversation again, at full price.
    public static func cacheWarm(_ reading: ContextReading?, now: Date) -> Bool {
        guard let reading, let at = reading.cacheAt, let lifetime = reading.cacheLifetime else { return false }
        return at.addingTimeInterval(lifetime) > now
    }

    // MARK: - Attachments

    /// Where attachments go, inside the project, kept out of git (P11).
    public static let attachmentFolder = ".lampboard/allegati"

    /// A name for a file put in the attachments: its last component, plain
    /// characters only, never hidden, never one already there.
    public static func attachmentName(_ original: String, taken: Set<String>) -> String {
        let last = (original as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension
        let stem = (last as NSString).deletingPathExtension
        func plain(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII { out.unicodeScalars.append(scalar) }
                else if scalar == "." || scalar == "_" || scalar == "-" { out.unicodeScalars.append(scalar) }
                else if !out.hasSuffix("-") { out += "-" }
            }
            return out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        let base = plain(stem).isEmpty ? (ext.isEmpty ? "file" : plain(ext)) : plain(stem)
        let suffix = plain(stem).isEmpty || plain(ext).isEmpty ? "" : "." + plain(ext).lowercased()
        var name = base + suffix
        var n = 2
        while taken.contains(name) {
            name = "\(base)-\(n)\(suffix)"
            n += 1
        }
        return name
    }

    /// How a message cites an attachment: a path the session's Read takes.
    public static func citation(of name: String) -> String { "@\(attachmentFolder)/\(name)" }
}
