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
    }

    /// This Mac's allowance and every configured node's, gathered.
    ///
    /// The nodes are asked **in parallel** and each on its own: a sleeping box
    /// costs one timed-out ssh, never the whole strip. The local reading comes
    /// first so that, when the same account is signed in on two machines, the copy
    /// whose age this app controls is the one kept.
    static func readAll(hosts: [String]) async -> Gathering {
        async let local = read()
        async let remote = remoteReports(hosts: hosts)

        var reports: [AllowanceReport] = []
        var quiet: String?
        switch await local {
        case .report(let report): reports.append(report)
        case .quiet(let reason):
            quiet = reason
            // Said in the log, because the strip says it only when there is
            // nothing at all to draw: with a node answering, a Mac that cannot
            // read its own token is a line that is simply missing, and the
            // afternoon spent on exactly that had nothing to read.
            Diagnostics.log("allowance local: \(reason)")
        }
        reports.append(contentsOf: await remote)

        return Gathering(
            reports: AllowanceReport.merged(reports),
            quiet: reports.isEmpty ? quiet : nil
        )
    }

    /// Each node's allowance, asked there rather than here.
    ///
    /// The request is made **on the node**, and only the answer crosses the wire.
    /// Pulling the token back would put a credential in this app's memory for the
    /// sake of three percentages, and the node already has both the credential and
    /// a network.
    private static func remoteReports(hosts: [String]) async -> [AllowanceReport] {
        guard !hosts.isEmpty else { return [] }
        return await withTaskGroup(of: AllowanceReport?.self) { group in
            for host in hosts {
                group.addTask { remoteReport(host: host) }
            }
            var found: [AllowanceReport] = []
            for await report in group {
                if let report { found.append(report) }
            }
            // The order a task group finishes in is the order the network answered,
            // which would reshuffle the strip on every poll. Sorted so a group of
            // bars stays where the eye left it.
            return found.sorted { $0.label < $1.label }
        }
    }

    private static func remoteReport(host: String) -> AllowanceReport? {
        let answer = RemoteCommand.runPythonForObject(
            on: host, script: RemoteAllowanceScript.script
        )
        guard case .success(let object) = answer else { return nil }
        // An error the node reported is an ordinary absence — signed out, token
        // aged out — and is logged rather than drawn.
        guard let payload = object["limits"] else {
            if let reason = object["error"] as? String {
                Diagnostics.log("allowance \(host): \(reason)")
            }
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let limits = AccountLimits.decode(data), !limits.limits.isEmpty
        else { return nil }

        var account: ClaudeAccount?
        if let named = object["account"] as? [String: Any] {
            account = ClaudeAccount(
                email: (named["email"] as? String)?.trimmed.nilIfEmpty,
                uuid: (named["uuid"] as? String)?.trimmed.nilIfEmpty
            )
        }
        return AllowanceReport(account: account, machine: host, limits: limits)
    }

    /// The name this Mac goes by when the account cannot say who it is.
    static let localMachine = "this Mac"

    static func read() async -> Outcome {
        guard let token = accessToken() else {
            return .quiet("Claude Code is not signed in on this Mac")
        }
        // Read before the request, and never fatal. A machine that cannot say which
        // account it is still draws its bars, labelled by the machine — the figures
        // are the point, the address is what disambiguates them.
        let account = localAccount()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = AppConfig.usageRequestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let limits = AccountLimits.decode(data) else {
                    return .quiet("the allowance answer could not be read")
                }
                return .report(
                    AllowanceReport(account: account, machine: localMachine, limits: limits)
                )
            case 401, 403:
                // The expected ending, not a fault: the borrowed token has aged
                // out and only Claude Code can replace it. Worded so that nobody
                // goes looking for a broken setting.
                return .quiet("waiting for Claude Code to refresh its sign-in")
            default:
                return .quiet("the allowance service answered \(status)")
            }
        } catch {
            return .quiet("the allowance could not be reached")
        }
    }

    /// Which account this Mac is signed in as. Free to read: it lives in
    /// `~/.claude.json`, which is not a secret.
    static func localAccount() -> ClaudeAccount? {
        guard let data = try? Data(contentsOf: AppConfig.claudeConfigURL) else { return nil }
        return ClaudeAccount.decode(data)
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
