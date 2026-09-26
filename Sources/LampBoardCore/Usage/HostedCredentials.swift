import Foundation

/// The accounts Claude Code is spending without having signed in itself.
///
/// WHY THIS EXISTS
/// The Claude application runs Claude Code for its own sessions, on this Mac or
/// on a machine it reaches over ssh, and signs it in as **the application's
/// account**, not the one `claude` was logged into. The credential is handed over
/// in the environment, `CLAUDE_CODE_OAUTH_TOKEN`, and nowhere else: not in the
/// keychain, not in `~/.claude/.credentials.json`. Measured on 26 September 2026
/// on a node where the application's sessions ran as a Team account while the
/// file there held a personal one: the strip drew the personal account and knew
/// nothing of the other, which was the one being spent that morning.
///
/// So the running Claude Code processes are the only place that account can be
/// read. Only processes of the same user are looked at, which is what the
/// operating system allows anyway, and only those that are Claude Code — the
/// entrypoint variable is set by Claude Code and inherited by what it starts.
///
/// BORROWED LIKE THE OTHER ONE
/// The rule for the keychain token holds here word for word (D46): read, used to
/// ask two questions, never stored, never renewed. There is no refresh token in
/// the environment to be tempted by, and the application renews its own.
public enum HostedCredentials {

    /// Where the token is handed over.
    public static let tokenVariable = "CLAUDE_CODE_OAUTH_TOKEN"

    /// Set by Claude Code and inherited by its children: what says a process is
    /// Claude Code's rather than anybody else's that happens to carry a token.
    public static let entrypointVariable = "CLAUDE_CODE_ENTRYPOINT"

    /// Who the account is. Asked with the same token, because the environment
    /// names nothing but the credential.
    public static let profileEndpoint = "https://api.anthropic.com/api/oauth/profile"

    /// More than this is somebody running something unusual, and every token
    /// costs two requests per poll. The first ones found are kept.
    public static let maximumAccounts = 4

    /// The tokens in a process listing, first seen first, each once.
    ///
    /// The listing is what `ps -Eww -axo command=` prints on a Mac: one process a
    /// line, the command and then its environment, separated by spaces. A session
    /// and every server it started carry the same token, hence the deduplication.
    public static func tokens(inProcessListing listing: String) -> [String] {
        let pattern = "(?:^|\\s)\(tokenVariable)=(sk-ant-[A-Za-z0-9_-]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        var found: [String] = []
        for line in listing.split(separator: "\n") where line.contains("\(entrypointVariable)=") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  let token = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  !found.contains(token)
            else { continue }
            found.append(token)
            if found.count == maximumAccounts { break }
        }
        return found
    }

    /// The account the profile endpoint describes, or `nil` when it names nothing.
    public static func account(fromProfile payload: Data) -> ClaudeAccount? {
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let object = root["account"] as? [String: Any]
        else { return nil }
        let email = (object["email"] as? String)?.trimmed.nilIfEmpty
        let uuid = (object["uuid"] as? String)?.trimmed.nilIfEmpty
        guard email != nil || uuid != nil else { return nil }
        return ClaudeAccount(email: email, uuid: uuid)
    }
}
