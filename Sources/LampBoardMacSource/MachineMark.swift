import Foundation

/// The badge on a row of another machine: the machine's initial, where it
/// used to be `R` (Marco's yes of 17 October 2026, L.C5).
///
/// A host is what the person typed in Settings › Other Macs, an ssh
/// destination: the account before `@` is not the machine, and a port after
/// `:` is not either. The first letter or digit of what is left, upper case;
/// `R` when there is none, as before.
public enum MachineMark {
    public static func initial(host: String) -> String {
        var name = Substring(host.trimmingCharacters(in: .whitespacesAndNewlines))
        if let at = name.lastIndex(of: "@") { name = name[name.index(after: at)...] }
        guard let first = name.unicodeScalars.first(where: { CharacterSet.alphanumerics.contains($0) }) else { return "R" }
        return String(first).uppercased()
    }
}
