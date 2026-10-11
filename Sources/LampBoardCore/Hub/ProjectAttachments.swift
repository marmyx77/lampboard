import Foundation

/// Files put into a project for its session (P11): a picture or a log dropped
/// on a session whose folder is on another machine, where a path of this Mac
/// means nothing. Copied under the project's own attachments, out of git, and
/// cited as a path the session's Read takes.
public enum ProjectAttachments {

    /// Where attachments go, inside the project, kept out of git (P11).
    public static let folder = ".lampboard/allegati"

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
    public static func citation(of name: String) -> String { "@\(folder)/\(name)" }
}
