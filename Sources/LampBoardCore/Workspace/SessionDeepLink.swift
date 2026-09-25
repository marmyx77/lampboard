import Foundation

/// Builds the deep link that opens a session's Claude **tab**, not just the
/// window containing it.
///
/// The VS Code extension registers a URI handler for the `/open` path and reads
/// its `session` and `prompt` parameters, forwarding them to the internal command
/// `claude-vscode.primaryEditor.open`. Verified by reading `extension.js` of
/// version 2.1.220:
///
/// ```js
/// case "/open": {
///   let w = x.get("session"), E = x.get("prompt");
///   executeCommand("claude-vscode.primaryEditor.open", w, E);
/// }
/// ```
///
/// This is an extension's internal contract, not a public API: it can change
/// without warning. That is why opening the tab is a bonus layered on top of
/// activating the window, never a replacement — if it stops working, the click
/// still takes you to the right window.
public enum SessionDeepLink {

    /// Extension identifier, in the `publisher.name` form the `vscode://` scheme
    /// requires.
    public static let extensionIdentifier = "Anthropic.claude-code"

    /// URL that opens the tab of the given session.
    ///
    /// - Returns: `nil` when the session id is empty or not representable in a URL.
    public static func url(forSessionId sessionId: String) -> URL? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "vscode"
        components.host = extensionIdentifier
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: trimmed)]
        return components.url
    }

    /// URL that opens a **new** conversation in the focused window.
    ///
    /// Same path without the `session` parameter: the internal command receives
    /// `undefined` and opens an empty tab instead of reattaching to an existing
    /// session.
    public static var newConversationURL: URL? {
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = extensionIdentifier
        components.path = "/open"
        return components.url
    }
}

/// Whether a click may follow the window with the tab deep link.
///
/// The extension resolves the link in the focused window and reuses a tab only
/// if it already has a panel for that session; otherwise it **creates one**. It
/// has a panel for the sessions it started — entrypoint `claude-vscode` — and for
/// nothing else: `claude` typed in the integrated terminal sits in the same
/// window with no panel, and the link would open a second tab for it on every
/// click. The rule is therefore an allow-list of one, with the unknown case
/// permitted: a session adopted from the filesystem before its first hook has
/// no entrypoint yet, and today's behaviour is to open.
public enum DeepLinkPolicy {
    /// The entrypoint of the sessions the extension hosts.
    public static let hostedEntrypoint = "claude-vscode"

    public static func opensTab(entrypoint: String?) -> Bool {
        guard let entrypoint else { return true }
        return entrypoint == hostedEntrypoint
    }

    /// Whether a row may offer to start a **new** conversation in an editor.
    ///
    /// A different question from `opensTab`, and it was answered by accident.
    /// The menu item was gated on the row's `origin`, which a session found on
    /// disk does not have: adoption leaves it at the default, `.editor`. So a
    /// Codex row in a terminal offered "New conversation here", and taking it
    /// raised the terminal and then opened a **Claude** tab in an editor: two
    /// surfaces, neither of them the one that was asked for.
    ///
    /// The rule is what the item actually does. It opens a Claude Code
    /// conversation in an editor window, so it belongs to a Claude Code session
    /// that lives in one. Codex is another agent and its rows would get the
    /// wrong one; a Claude Desktop conversation has no editor tab to open.
    ///
    /// The unknown entrypoint is permitted, as it is above and for the same
    /// reason: a Claude Code session adopted from disk has none until its first
    /// hook, and refusing it would take the item away from a row that is about
    /// to prove it deserves it.
    public static func opensNewConversation(harness: Harness, entrypoint: String?) -> Bool {
        guard harness == .claudeCode else { return false }
        return !ClaudeDesktop.isEntrypoint(entrypoint)
    }
}
