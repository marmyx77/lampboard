import CryptoKit
import LampBoardCore
import Foundation

/// Asks Anthropic how much of the account's allowance is gone. Nothing else.
///
/// This is the **only** thing in the app that leaves the Mac besides the update
/// check, and the only one that reads a credential it did not create. It is off
/// unless the person turns it on, and the switch is the whole design: everything
/// below is what makes the switch honest.
///
/// THE TOKEN IS BORROWED, NEVER RENEWED
/// Claude Code keeps its OAuth pair in the login keychain under
/// `Claude Code-credentials`. Measured on 20 September 2026: the access token
/// lives **eight hours** and Claude Code rotates it there; the refresh token lasts
/// about four weeks. We hold the refresh token and could mint a new access token
/// ourselves. We must not. Refresh tokens are commonly rotated on use, so spending
/// it would invalidate the copy Claude Code holds and **sign the person out of the
/// tool this panel exists to watch**. A widget that logs you out of your editor is
/// not a trade anybody would accept, and the failure would look like Claude Code's
/// fault. So: read, use, and when it is too old to work, say nothing.
///
/// The consequence is deliberate. With no Claude Code session in eight hours the
/// token expires, the answer is a 401, and the strip goes quiet — which is exactly
/// the stretch in which nobody is spending any allowance.
///
/// NOTHING IS CACHED IN MEMORY
/// The keychain is read on every attempt, not once at launch. Anything held would
/// be a token going stale in our hands while the fresh one sits on disk a
/// centimetre away. The read goes through `/usr/bin/security`, the tool Claude
/// Code writes the item with, which is what keeps macOS from asking (D52).
enum AccountLimitsReader {

    /// What an attempt produced.
    enum Outcome: Equatable {
        case report(AllowanceReport)
        /// Nothing to draw, and a sentence for the tooltip saying why. Never an
        /// error dialog: this is decoration, and decoration does not interrupt.
        case quiet(String)
        /// Anthropic answered 429: asked too often, by everything that asks.
        case throttled
    }

    /// Where the figures come from. The same address `/usage` asks.
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The keychain item Claude Code writes its OAuth pair into.
    static let keychainService = "Claude Code-credentials"

    /// Everything the strip draws in one pass.
    struct Gathering {
        /// Local first, then the nodes, with repeats of one account collapsed.
        let reports: [AllowanceReport]
        /// The **local** reason for silence, and only when there is nothing at all
        /// to draw. A node that is signed out or unreachable says nothing: a strip
        /// about allowances that started listing hosts would have become a status
        /// board, and the panel has one of those already.
        let quiet: String?
        /// Some ask was answered 429. The monitor then keeps the last readings and
        /// waits longer before the next ask (`AllowanceThrottle`).
        let throttled: Bool
    }

    /// This Mac's allowance and every configured node's, gathered.
    ///
    /// The nodes are asked **in parallel** and each on its own: a sleeping box
    /// costs one timed-out ssh, never the whole strip. The local reading comes
    /// first so that, when the same account is signed in on two machines, the copy
    /// whose age this app controls is the one kept.
    static func readAll(hosts: [String]) async -> Gathering {
        // Every account is asked once a round, which is what stopped one account
        // being asked twice a poll and answered 429 (`AllowanceThrottle`). So
        // this Mac is asked first and the nodes are told which accounts it
        // already has — only those it **has**: a Mac whose token aged out must not
        // silence the node that is signed in to the same account and working.
        let local = await read()

        var reports: [AllowanceReport] = []
        var quiet: String?
        var throttled = false
        var have: [String] = []
        switch local {
        case .report(let report):
            reports.append(report)
            have += [report.account?.uuid].compactMap { $0 }
        case .quiet(let reason):
            quiet = reason
            // Said in the log, because the strip says it only when there is
            // nothing at all to draw: with a node answering, a Mac that cannot
            // read its own token is a line that is simply missing, and the
            // afternoon spent on exactly that had nothing to read.
            Diagnostics.log("allowance local: \(reason)")
        case .throttled:
            // Not skipped anywhere: the limit is kept per token, and another
            // token of the same account — the application's, a node's — may
            // still be answered.
            throttled = true
            quiet = "Anthropic asked to slow down (429)"
            Diagnostics.log("allowance local: answered 429")
        }
        let hosted = await hostedReports(skipping: have)
        have += hosted.0.compactMap(\.account?.uuid)
        let (fromHosted, hostedThrottled) = hosted
        let (fromNodes, nodesThrottled) = await remoteReports(hosts: hosts, skipping: have)
        reports.append(contentsOf: fromHosted)
        reports.append(contentsOf: fromNodes)
        throttled = throttled || hostedThrottled || nodesThrottled

        return Gathering(
            reports: AllowanceReport.merged(reports),
            quiet: reports.isEmpty ? quiet : nil,
            throttled: throttled
        )
    }

    /// Each node's allowance, asked there rather than here.
    ///
    /// The request is made **on the node**, and only the answer crosses the wire.
    /// Pulling the token back would put a credential in this app's memory for the
    /// sake of three percentages, and the node already has both the credential and
    /// a network.
    private static func remoteReports(
        hosts: [String], skipping: [String]
    ) async -> ([AllowanceReport], Bool) {
        guard !hosts.isEmpty else { return ([], false) }
        return await withTaskGroup(of: ([AllowanceReport], Bool).self) { group in
            for host in hosts {
                group.addTask { remoteReports(host: host, skipping: skipping) }
            }
            var found: [AllowanceReport] = []
            var throttled = false
            for await (reports, refused) in group {
                found.append(contentsOf: reports)
                throttled = throttled || refused
            }
            // The order a task group finishes in is the order the network answered,
            // which would reshuffle the strip on every poll. Sorted so a group of
            // bars stays where the eye left it.
            return (found.sorted { $0.label < $1.label }, throttled)
        }
    }

    /// A node's own sign-in and the accounts the Claude application runs there.
    private static func remoteReports(host: String, skipping: [String]) -> ([AllowanceReport], Bool) {
        let answer = RemoteCommand.runPythonForObject(
            on: host, script: RemoteAllowanceScript.script(skipping: skipping)
        )
        guard case .success(let object) = answer else { return ([], false) }
        // An error the node reported is an ordinary absence — signed out, token
        // aged out — and is logged rather than drawn.
        if let reason = object["error"] as? String {
            Diagnostics.log("allowance \(host): \(reason)")
        }
        return (RemoteAllowanceScript.reports(in: object, host: host), object["throttled"] as? Bool == true)
    }

    /// The name this Mac goes by when the account cannot say who it is.
    static let localMachine = "this Mac"

    static func read() async -> Outcome {
        guard let token = accessToken() else {
            return .quiet("Claude Code is not signed in on this Mac")
        }
        // Asked of the token, never read from `~/.claude.json` (D56), and never
        // fatal: a token that cannot say whose it is still draws its bars,
        // labelled by the machine.
        let account = await account(of: token)

        switch await ask(endpoint, token: token) {
        case .answer(let data):
            guard let limits = AccountLimits.decode(data) else {
                return .quiet("the allowance answer could not be read")
            }
            return .report(
                AllowanceReport(account: account, machine: localMachine, limits: limits)
            )
        case .refused:
            // The expected ending, not a fault: the borrowed token has aged
            // out and only Claude Code can replace it. Worded so that nobody
            // goes looking for a broken setting.
            return .quiet("waiting for Claude Code to refresh its sign-in")
        case .throttled:
            return .throttled
        case .status(let status):
            return .quiet("the allowance service answered \(status)")
        case .unreachable:
            return .quiet("the allowance could not be reached")
        }
    }

    /// The accounts the Claude application runs Claude Code as on this Mac.
    ///
    /// Read out of the environment of the running processes, the only place the
    /// application puts them (`HostedCredentials`). No application session running
    /// means nothing found, and nothing is said: the strip has nothing to report
    /// about an account nobody is spending.
    static func hostedReports(skipping: [String]) async -> ([AllowanceReport], Bool) {
        guard let listing = try? Command.run(
            "/bin/ps", ["-Eww", "-axo", "command="],
            deadline: AppConfig.focusProbeTimeout,
            capturingStandardError: false
        ), listing.status == 0 else { return ([], false) }

        var reports: [AllowanceReport] = []
        var asked = Set(skipping)
        var throttled = false
        for token in HostedCredentials.tokens(inProcessListing: listing.output) {
            // Who the token belongs to, asked once per token and remembered by a
            // hash of it: the figures of an account already asked this round are
            // not asked for again.
            let account = await account(of: token)
            // Only an answer counts: a refused token leaves its account to the
            // next token of it (see `RemoteAllowanceScript.script(skipping:)`).
            if let uuid = account?.uuid, asked.contains(uuid) { continue }
            switch await ask(endpoint, token: token) {
            case .answer(let data):
                guard let limits = AccountLimits.decode(data), !limits.limits.isEmpty else { continue }
                if let uuid = account?.uuid { asked.insert(uuid) }
                reports.append(AllowanceReport(account: account, machine: localMachine, limits: limits))
            case .throttled:
                throttled = true
            default:
                continue
            }
        }
        return (reports, throttled)
    }

    /// The accounts of the application's tokens, keyed by a hash of each token so
    /// that no credential is kept in memory between rounds.
    private static let tokenAccounts = TokenAccounts()

    private final class TokenAccounts: @unchecked Sendable {
        private let lock = NSLock()
        private var byHash: [String: ClaudeAccount] = [:]

        private static func key(_ token: String) -> String {
            SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        func account(for token: String) -> ClaudeAccount? {
            lock.lock(); defer { lock.unlock() }
            return byHash[Self.key(token)]
        }

        func remember(_ account: ClaudeAccount, for token: String) {
            lock.lock(); defer { lock.unlock() }
            // Tokens are renewed by the application every few hours; a handful of
            // stale entries is harmless, an unbounded list is not.
            if byHash.count >= HostedCredentials.maximumAccounts * 4 { byHash.removeAll() }
            byHash[Self.key(token)] = account
        }

        var uuids: [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(Set(byHash.values.compactMap(\.uuid)))
        }
    }

    private enum Answer {
        case answer(Data)
        case refused
        case throttled
        case status(Int)
        case unreachable
    }

    /// One signed GET. The token goes in the header and nowhere else.
    private static func ask(_ url: URL, token: String) async -> Answer {
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConfig.usageRequestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .answer(data)
            case 401, 403: return .refused
            case 429: return .throttled
            case let status: return .status(status)
            }
        } catch {
            return .unreachable
        }
    }

    /// Whose a token is: asked of the profile endpoint with the token itself,
    /// once per token, and remembered by a hash of it.
    ///
    /// NOT `~/.claude.json`. That file names the account of the last sign-in any
    /// Claude Code on this Mac went through, and the keychain holds the token of
    /// whichever sign-in wrote it — two things that can disagree. Measured on 30
    /// September 2026: the file said the organization account, the keychain's
    /// token was the personal one. The strip drew the personal account's figures
    /// under the organization's address, and told the node it already had the
    /// organization's account, so the node skipped the only tokens that really
    /// were it. The token cannot be wrong about itself (D56).
    static func account(of token: String) async -> ClaudeAccount? {
        if let known = tokenAccounts.account(for: token) { return known }
        guard let profile = URL(string: HostedCredentials.profileEndpoint),
              case .answer(let named) = await ask(profile, token: token),
              let account = HostedCredentials.account(fromProfile: named)
        else { return nil }
        tokenAccounts.remember(account, for: token)
        return account
    }

    // MARK: - The borrowed credential

    /// Reads Claude Code's current access token out of the login keychain —
    /// **through `/usr/bin/security`**, the tool Claude Code writes it with.
    ///
    /// Returns `nil` for every failure, with no distinction between them: none of
    /// them is actionable by the person reading the panel, and a strip that
    /// explained keychain status codes would be answering a question nobody asked.
    ///
    /// Why the tool and not the framework. The first version called
    /// `SecItemCopyMatching` from this process, and macOS put up "LampBoard wants
    /// to access the key" — at every launch, because *Allow* covers the running
    /// process only, and *Always Allow* adds the app **at its path** to the
    /// item's access list: pressed on the build in `dist/`, it did nothing for the
    /// copy in `/Applications`, and a person who updated four times in a day saw
    /// the dialog four times. Read on 22 September 2026 with `security
    /// dump-keychain -a`: the item's decrypt entry trusts exactly two programs,
    /// `/usr/bin/security` — Claude Code's own writer — and whichever copy of this
    /// app somebody had once pressed *Always* for. The tool is trusted for as long
    /// as Claude Code keeps writing through it, whatever this app is called or
    /// where it lives, and a read through it asks nobody anything (D52).
    ///
    /// The earlier note here — that the item carried no access-control list and
    /// an ad-hoc binary read it without a dialog — was wrong, or was measured
    /// through this same tool without noticing. Replaced by what the dump says.
    static func accessToken() -> String? {
        guard let result = try? Command.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", keychainService, "-a", NSUserName(), "-w"],
            deadline: AppConfig.focusProbeTimeout,
            capturingStandardError: false
        ), result.status == 0 else { return nil }
        // `-w` prints the secret and a newline; the secret is the JSON blob the
        // parser reads, and only its access token leaves that parser.
        return ClaudeCredentials.accessToken(in: Data(result.output.trimmed.utf8))
    }
}
