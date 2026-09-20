import Foundation

/// Reads the OAuth pair Claude Code keeps for itself.
///
/// Only the shape lives here — finding the item is the app's job, because it needs
/// the keychain. Separated so the part that can be got wrong silently can be
/// checked without a keychain to check against.
///
/// **The credential is borrowed and never spent.** The blob also carries a refresh
/// token and its expiry, and neither is read by this type. That omission is the
/// design: refresh tokens are commonly rotated on use, so minting a new access
/// token with Claude Code's refresh token could invalidate the copy Claude Code
/// holds and sign the person out of it. There is no function here that could do
/// that, which is a stronger guarantee than a comment asking nobody to.
public enum ClaudeCredentials {

    /// The access token inside the keychain blob, or `nil` for anything else.
    ///
    /// The pair sits under `claudeAiOauth`; a bare object is accepted too, so that a
    /// change of nesting empties the strip instead of breaking the app around it.
    public static func accessToken(in payload: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }
        let object = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = object["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
