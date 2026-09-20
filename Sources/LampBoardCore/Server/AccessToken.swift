import Foundation

/// The secret that authorizes reading the column state.
///
/// It exists because `GET /sessions` exposes the names and paths of the open
/// projects, and on a development machine those are information: client names,
/// unannounced products, folders that say what is being worked on.
///
/// **What it really protects against, and what it doesn't.** The token lives in a
/// `0600` file, so it stops the other users on the machine and anyone coming from
/// the network — the socket is already bound to loopback. It does **not** stop a
/// process running as your own user: that one can open the file, and no on-disk
/// secret can prevent it. Claude Code sessions fall into that category.
///
/// It is still worth having: it raises the barrier from "a GET is enough" to "you
/// have to know where the token lives and read it", and it fully covers the
/// multi-user case. But presenting it as a defense against the code running inside
/// the sessions would be a false reassurance, and that is worse than no defense at
/// all, because people stop thinking about it.
///
/// The endpoint that *receives* the signals used to stay open, on the reasoning
/// that a hook failing authentication would block a Claude Code turn for the sake
/// of a decorative widget. That premise was never measured, and when it finally
/// was it did not hold: a hook whose endpoint refuses it costs the turn nothing,
/// and a `401` is swallowed without a word reaching the person at the keyboard.
/// `POST /signal` now refuses a token that is present and wrong, while still
/// accepting one that is absent — see `SignalServer.handleSignal` for why the two
/// cases are treated differently, and for how long.
///
/// It remains true that this stops nobody running as your own user, sessions
/// included: they can read the file. What it adds is that a forged signal now has
/// to omit the header rather than guess it, which is the step that makes
/// *requiring* it later a change of one line instead of a redesign.
public enum AccessToken {

    /// Name of the header carrying the token.
    public static let headerName = "X-LampBoard-Token"

    /// The name it had before the rename, still accepted on the way in.
    ///
    /// Same reasoning as the host header: a client configured under the old name
    /// — a `curl` in someone's script, a remote node — would start getting 401
    /// from a release that only changed a word. Read, never written.
    public static let legacyHeaderName = "X-Clawd-Token"

    /// Number of bytes of entropy generated.
    public static let byteCount = 24

    /// Generates a fresh token: 24 random bytes in hexadecimal.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `true` when `candidate` matches `expected`.
    ///
    /// The comparison always walks every byte and accumulates the differences
    /// instead of bailing out at the first mismatching character. A plain `==`
    /// returns early, and how long it takes tells you how many leading characters
    /// were right: that is enough to reconstruct the token one character at a time.
    /// Over loopback the attack is hard, not impossible, and writing it properly
    /// costs one line.
    public static func matches(_ candidate: String?, expected: String) -> Bool {
        guard let candidate else { return false }
        let lhs = Array(candidate.utf8)
        let rhs = Array(expected.utf8)
        guard !rhs.isEmpty else { return false }

        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }

    /// `true` when the string has the shape of a token generated here.
    public static func isWellFormed(_ token: String) -> Bool {
        token.count == byteCount * 2
            && token.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
