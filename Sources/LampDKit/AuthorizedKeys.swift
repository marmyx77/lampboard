import Foundation

/// The phone's lines in `~/.ssh/authorized_keys`, and only those (§2.4, ADR-65
/// point 8).
///
/// Each paired device has two keys and so two lines, each ending in a marker
/// `lampboard-device:<id>:read` or `…:action`. The read key's line forces the
/// one command it may run — `lampd v1-stdio --device <id>` — with `restrict`
/// (no terminal, no forwarding, no agent) and `from=`; the action key's line is
/// `restrict,pty` with the same `from=`. Every other line of the file belongs to
/// somebody else (the home mesh of `deploy/rete`, M11) and is given back byte
/// for byte: the functions here never rewrite a line they did not write, and
/// `rewrite` refuses to return a file in which the other lines moved.
public enum AuthorizedKeys {

    public enum Role: String, Sendable, CaseIterable {
        case read, action
    }

    public static let markerPrefix = "lampboard-device:"

    /// A device's id: lowercase letters, digits and dashes, 1 to 40, starting
    /// with a letter or a digit. It goes into a command line and a comment, so
    /// nothing in it can be read as anything else.
    public static func isDeviceId(_ id: String) -> Bool {
        guard (1...40).contains(id.count), let first = id.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0) && !CharacterSet.uppercaseLetters.contains($0)) || $0 == "-" }
    }

    public static func marker(_ id: String, _ role: Role) -> String { "\(markerPrefix)\(id):\(role.rawValue)" }

    /// The key types a phone's key can be: P-256, what the Secure Enclave makes
    /// and OpenSSH calls `ecdsa-sha2-nistp256`; and Ed25519, for the checks'
    /// keys. Nothing else.
    public static let keyTypes: Set<String> = ["ecdsa-sha2-nistp256", "ssh-ed25519"]

    /// `<type> <base64>` from what the app shows, or why it is not a key.
    ///
    /// The base64 must decode, and the blob must name the same type it is
    /// filed under: a line is assembled from this, and a "key" that carries
    /// options, quotes or a second line would become part of the file's syntax.
    public static func publicKey(_ text: String) -> Result<String, LampDError> {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, parts.count <= 3, !text.contains("\n"), !text.contains("\r") else {
            return .failure(.invalid("a public key is `<type> <base64>` on one line"))
        }
        let type = String(parts[0]), body = String(parts[1])
        guard keyTypes.contains(type) else {
            return .failure(.invalid("\(type) is not a key type a phone uses (\(keyTypes.sorted().joined(separator: ", ")))"))
        }
        guard body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }),
              let blob = Data(base64Encoded: body), blob.count >= 4 else {
            return .failure(.invalid("the key's body is not base64"))
        }
        let length = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        guard length == type.utf8.count, blob.count >= 4 + length,
              String(decoding: blob[4..<(4 + length)], as: UTF8.self) == type else {
            return .failure(.invalid("the key's body is not a \(type) key"))
        }
        return .success("\(type) \(body)")
    }

    /// `from=`'s value, checked: addresses and networks only, so that nothing in
    /// it can close the option's quotes.
    public static func fromList(_ patterns: [String]) -> Result<String, LampDError> {
        guard !patterns.isEmpty else { return .failure(.invalid("from= needs at least one network")) }
        for pattern in patterns {
            let allowed = pattern.unicodeScalars.allSatisfy {
                $0.properties.isASCIIHexDigit || $0 == "." || $0 == ":" || $0 == "/"
            }
            guard allowed, !pattern.isEmpty, pattern.count <= 64 else {
                return .failure(.invalid("\(pattern) is not an address or a network"))
            }
        }
        return .success(patterns.joined(separator: ","))
    }

    /// The two lines of a device.
    /// - Parameter command: the absolute path of `lampd` as sshd will run it.
    public static func lines(device: String, readKey: String, actionKey: String, from: String, command: String) -> [String] {
        [
            "restrict,from=\"\(from)\",command=\"\(command) v1-stdio --device \(device)\" \(readKey) \(marker(device, .read))",
            "restrict,pty,from=\"\(from)\" \(actionKey) \(marker(device, .action))",
        ]
    }

    /// The device and role a line belongs to, when it is one of `lampd`'s.
    public static func owner(of line: String) -> (device: String, role: Role)? {
        guard let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last, last.hasPrefix(markerPrefix) else { return nil }
        let parts = last.dropFirst(markerPrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, isDeviceId(String(parts[0])), let role = Role(rawValue: String(parts[1])) else { return nil }
        return (String(parts[0]), role)
    }

    /// The devices with lines in `text`, in the order their first line appears.
    public static func devices(in text: String) -> [(device: String, roles: [Role])] {
        var order: [String] = []
        var roles: [String: [Role]] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let found = owner(of: line) else { continue }
            if roles[found.device] == nil { order.append(found.device) }
            roles[found.device, default: []].append(found.role)
        }
        return order.map { ($0, roles[$0] ?? []) }
    }

    /// `text` without `device`'s lines, and with `added` at the end.
    ///
    /// Refuses to give back a file whose other lines are not exactly the ones it
    /// was given, in the same order: a defect here would lock the house out.
    public static func rewrite(_ text: String, removing device: String?, adding added: [String]) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let endedWithNewline = text.hasSuffix("\n") || text.isEmpty
        if text.hasSuffix("\n") { lines.removeLast() }
        if text.isEmpty { lines = [] }
        let kept = lines.filter { line in
            guard let device, let found = owner(of: line) else { return true }
            return found.device != device
        }
        var out = kept + added
        // Never a file of only blank lines from an empty one.
        if out.isEmpty { return "" }
        if !endedWithNewline && added.isEmpty && kept.count == lines.count { return text }
        out.append("")
        let result = out.joined(separator: "\n")
        guard others(in: result) == others(in: text) else {
            throw LampDError.invalid("refused: the lines that are not LampBoard's would have changed")
        }
        return result
    }

    /// The lines that are not `lampd`'s, as they are.
    static func others(in text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines.filter { owner(of: $0) == nil && !$0.isEmpty }
    }
}
