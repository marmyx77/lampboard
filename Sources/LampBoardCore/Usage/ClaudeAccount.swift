import Foundation

/// Which Claude account a machine is signed in as.
///
/// WHY THIS EXISTS AT ALL
/// The allowance strip was built reading one machine's credentials and drawing one
/// set of bars, on the unexamined assumption that a person has one account. That
/// assumption is wrong here and probably wrong for anybody working across a laptop
/// and a build box: measured on 20 September 2026, this Mac is signed in as an
/// organization account on a Team plan, and the node the tunnel reaches — where
/// most of the work actually happens — is a personal account on a Max plan. Two
/// accounts, two allowances, two different **sizes** of allowance.
///
/// A single unlabelled bar reading "36%" in that situation is not incomplete, it is
/// wrong: it invites the reading that this is *your* remaining room, while the
/// sessions burning through the other account's allowance sit in the same column a
/// few points above. So an allowance is never drawn without knowing whose it is.
///
/// The identity is free. It sits in `~/.claude.json`, which is not a secret and
/// needs no credential to read; the token is needed for the figures, never for the
/// name.
public struct ClaudeAccount: Equatable, Sendable {

    /// The address the person recognizes. Optional because a configuration can
    /// carry the uuid and not the address, and a bar labelled with a uuid is worse
    /// than one labelled with the machine it came from.
    public let email: String?

    /// The stable identity. This, and not the address, is what says two machines
    /// are spending the same allowance: the same account signed in twice must draw
    /// one set of bars, or the strip claims the person has twice the room.
    public let uuid: String?

    public init(email: String?, uuid: String?) {
        self.email = email
        self.uuid = uuid
    }

    /// `nil` when nothing usable was found, so that a caller cannot end up holding
    /// an account that names nothing.
    public static func decode(_ payload: Data) -> ClaudeAccount? {
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }
        let object = (root["oauthAccount"] as? [String: Any]) ?? [:]
        let email = (object["emailAddress"] as? String)?.trimmed.nilIfEmpty
        // The cached allowance block carries the same uuid, and is read as a
        // fallback: a configuration that has been signed in and out can hold one
        // and not the other.
        let cached = (root["cachedUsageUtilization"] as? [String: Any])?["accountUuid"] as? String
        let uuid = (object["accountUuid"] as? String)?.trimmed.nilIfEmpty ?? cached?.trimmed.nilIfEmpty

        guard email != nil || uuid != nil else { return nil }
        return ClaudeAccount(email: email, uuid: uuid)
    }

    /// What to write above a group of bars.
    ///
    /// The address when there is one. Otherwise the machine, which is the thing the
    /// person can still act on — they know which box that is even when the
    /// configuration there has forgotten its own address.
    public func label(fallback machine: String) -> String {
        email ?? machine
    }

    /// Two readings that are the same allowance.
    ///
    /// Matched on the uuid alone. Two machines signed into one account must not
    /// draw two sets of bars, and the address is not enough to decide it: it can be
    /// absent on one side, and it is the uuid the answer is actually keyed on.
    /// Without a uuid on either side the answer is *no* — drawing one group twice
    /// is a smaller mistake than silently hiding a second account's allowance.
    public func isSameAccount(as other: ClaudeAccount) -> Bool {
        guard let uuid, let theirs = other.uuid else { return false }
        return uuid == theirs
    }
}
