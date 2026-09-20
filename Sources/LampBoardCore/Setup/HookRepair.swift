import Foundation

/// Whether an installation needs bringing up to the current token, and what
/// shape it has to keep when it is.
///
/// One rule for both installers, because they answer the same question about
/// two different files: the local `settings.json` at launch, and a node's, read
/// over ssh when the panel connects to it. The first version lived inside the
/// local installer alone, and the node was left to a person remembering to press
/// a button — which works for the one machine its author knows about and for
/// nobody else's.
///
/// Three things are read and nothing is assumed: which events carry one of our
/// registrations, which listener they are addressed to, and whether the token is
/// in both the native headers and the script's text. An installation addressed
/// to another port is somebody else's to keep (D48).
public enum HookRepair {

    /// What an installation had, and must keep through a repair.
    public struct Shape: Equatable, Sendable {
        public let includeToolEvents: Bool
        public let includeMessageDelivery: Bool

        public init(includeToolEvents: Bool, includeMessageDelivery: Bool) {
            self.includeToolEvents = includeToolEvents
            self.includeMessageDelivery = includeMessageDelivery
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// No registration of ours in the file.
        case nothingInstalled
        /// Our registrations, posting to a listener that is not this one.
        case addressedElsewhere
        /// Both halves carry the token.
        case current
        /// One half or both lack it; rewrite both, keeping this shape.
        case stale(Shape)
    }

    /// - Parameters:
    ///   - settings: the hooks file as read.
    ///   - scriptPath: where our script lives on that machine, as the file names it.
    ///   - legacyScriptPaths: where it lived under the project's previous name.
    ///     Registrations naming those are ours too — the commonest stale
    ///     installation there is, and the one a rule that knew only the current
    ///     name would have read as "nothing installed" and left to die.
    ///   - rewakeScriptPath: the message listener's path, or `nil` where the
    ///     feature does not exist — Codex, every remote node.
    ///   - scriptText: the script as read — the current one, or failing that the
    ///     previous name's — `nil` when neither is there.
    ///   - token: the value the installation has to carry.
    ///   - port: the listener asking. Locally the app's port; on a node the
    ///     loopback port the tunnel binds for that user.
    public static func verdict(
        settings: [String: Any],
        scriptPath: String,
        legacyScriptPaths: [String] = [],
        rewakeScriptPath: String?,
        scriptText: String?,
        token: String,
        port: UInt16
    ) -> Verdict {
        let events = ([scriptPath] + legacyScriptPaths)
            .flatMap { HookConfigMerger.installedEvents(in: settings, scriptPath: $0) }
        guard !events.isEmpty else { return .nothingInstalled }
        guard isAddressed(to: port, settings: settings, scriptText: scriptText) else {
            return .addressedElsewhere
        }

        let headerStale = HookConfigMerger.lacksToken(in: settings, scriptPath: scriptPath, token: token)
        let scriptStale = !(scriptText?.contains(token) ?? false)
        guard headerStale || scriptStale else { return .current }

        return .stale(Shape(
            includeToolEvents: HookConfigMerger.toolEvents.allSatisfy(events.contains),
            // By command path, never by `isInstalled`: that one also claims the
            // native hooks, and would report a listener on every file that has
            // none — turning message delivery on for people who never asked.
            includeMessageDelivery: rewakeScriptPath.map {
                HookConfigMerger.hasCommandHook(at: $0, in: settings)
            } ?? false
        ))
    }

    /// `true` when the installed hooks post to `port`.
    ///
    /// The native registrations say so in their URL. When there are none — Codex
    /// keeps everything on the script, and so did every installation before 0.4 —
    /// the script's own target is the record, and an installation with neither is
    /// nobody's to repair.
    static func isAddressed(to port: UInt16, settings: [String: Any], scriptText: String?) -> Bool {
        let native = HookConfigMerger.nativePorts(in: settings)
        if !native.isEmpty { return native == [port] }
        guard let scriptText else { return false }
        return HookScriptBuilder.posts(scriptText, to: port)
    }
}
