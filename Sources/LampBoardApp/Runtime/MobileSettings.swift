import Foundation
import LampBoardCore
import LampBoardMacSource
import Security

/// What the person chose for iPhone & iPad (W5, §2.6), kept beside the other
/// preferences, in the same domain (a test home has its own).
struct MobileSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = Preferences.sharedDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let terminals = "mobile.terminalsAndActions"
        static let port = "mobile.port"
    }

    /// «Terminal and actions from iPhone & iPad» (Q17): off until the person
    /// turns it on. A test home may turn it on with `LAMPBOARD_MOBILE_TERMINALS=1`.
    var terminalsOn: Bool {
        get {
            if AppConfig.isUsingHomeOverride, ProcessInfo.processInfo.environment["LAMPBOARD_MOBILE_TERMINALS"] == "1" { return true }
            return defaults.bool(forKey: Key.terminals)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.terminals) }
    }

    /// The port the server took the first time, kept so that a paired phone
    /// finds it again; a test home names its own with `LAMPBOARD_MOBILE_PORT`.
    var port: Int {
        get {
            if AppConfig.isUsingHomeOverride, let forced = ProcessInfo.processInfo.environment["LAMPBOARD_MOBILE_PORT"].flatMap(Int.init) {
                return forced
            }
            return defaults.integer(forKey: Key.port)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.port) }
    }

    /// Where the paired devices and, in a test home, the host key live.
    static var directory: String { AppConfig.supportDirectory.appendingPathComponent("mobile").path }

    /// The server's host key: the Keychain on a person's Mac, a file in a fake
    /// home (a locked login keychain must not stop a suite).
    static var hostKeyStore: MacHostKey.Store {
        AppConfig.isUsingHomeOverride ? MacHostKey.FileStore(path: directory + "/host_key") : KeychainHostKey()
    }
}

/// The host key in the login Keychain, readable only by this Mac once unlocked.
struct KeychainHostKey: MacHostKey.Store {
    private static let service = "app.lampboard.mobile-host-key"
    private static let account = "ed25519"

    func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func save(_ raw: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = raw
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "LampBoard iPhone & iPad host key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw MacSourceError.unavailable("the Keychain refused the host key (\(status))") }
    }
}
