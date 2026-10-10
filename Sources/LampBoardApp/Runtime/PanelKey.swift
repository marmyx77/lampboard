import CryptoKit
import Foundation
import LampBoardCore
import Security

/// The panel's Ed25519 key (D152): it signs the commands the Hub sends to a
/// session's mod and the panel's hello.
///
/// The private half lives in the Keychain, where a session's Bash cannot read
/// it without the person seeing a dialog; the public half is written to
/// `~/.lampboard/panel-key.pub` for the mod. Under a fake home (tests, the test
/// Mac's probes) both halves are files, because a locked login keychain must not
/// stop a suite — and nothing real is reachable from a fake home.
enum PanelKey {

    private static let service = "app.lampboard.panel-key"
    private static let account = "ed25519"

    /// The key, created on first use; `nil` when neither the Keychain nor the
    /// disk cooperates, and then the Hub sends nothing rather than unsigned.
    static func loadOrCreate() -> Curve25519.Signing.PrivateKey? {
        let key = AppConfig.isUsingHomeOverride ? fromTestFile() : fromKeychain()
        if let key { publish(key.publicKey) }
        return key
    }

    /// The public half, hex, where the mod reads it. Rewritten at every launch:
    /// a file somebody replaced is put back, and a key the Keychain lost is
    /// replaced everywhere at once.
    static func publish(_ publicKey: Curve25519.Signing.PublicKey) {
        let url = AppConfig.panelKeyPublicURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = CommandEnvelope.hex(publicKey.rawRepresentation) + "\n"
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o644])
    }

    // MARK: - Keychain

    private static func fromKeychain() -> Curve25519.Signing.PrivateKey? {
        if let raw = readKeychain(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        return writeKeychain(key.rawRepresentation) ? key : nil
    }

    private static func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func writeKeychain(_ raw: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = raw
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "LampBoard panel key"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Diagnostics.log("panel key not stored in the Keychain: \(status)") }
        return status == errSecSuccess
    }

    // MARK: - Fake home

    private static func fromTestFile() -> Curve25519.Signing.PrivateKey? {
        let url = AppConfig.panelKeyTestURL
        if let raw = try? Data(contentsOf: url), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
        else { return nil }
        return key
    }
}
