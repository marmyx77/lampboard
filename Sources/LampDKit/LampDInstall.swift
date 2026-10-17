import Foundation
import LampBoardCore

public enum LampDVersion {
    /// Raised with each release of `lampd`; `hello` carries it to the phone.
    public static let current = "0.1.0"
}

/// Where `lampd` is installed (ADR-65 point 2): the binary in
/// `~/.local/lib/lampd/<version>/lampd`, and the link `~/.local/bin/lampd`
/// that the unit and the read keys' lines run. A key's line names the link,
/// never a version, so an update does not lock a phone out.
public enum LampDInstall {
    public static func commandPath(home: String) -> String { home + "/.local/bin/lampd" }
}

/// A device's id when the person does not give one: the name made into a word,
/// and six characters of the read key's digest, so two phones of the same name
/// are two devices.
public enum DeviceIds {
    public static func make(name: String, readKey: String) -> String {
        let word = name.lowercased().unicodeScalars
            .map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-" }
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = String(word.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var hash: UInt32 = 2_166_136_261
        for byte in readKey.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let suffix = String(String(hash, radix: 16).suffix(6))
        return (base.isEmpty ? "device" : base) + "-" + suffix
    }
}
