import LampBoardCore
import Foundation

/// Both agents' hooks, asked and answered together.
///
/// It exists because the answer used to depend on **how** you asked. The command
/// line installed Claude Code and then Codex; the first-run offer, the context
/// menu and the state that menu showed all consulted a single installer and it
/// was always Claude's. So a person who accepted the offer at first launch had
/// Codex left unregistered, silently, and the panel told them the hooks were
/// installed — which was true of one agent and false of the other.
///
/// One place asks now, and it answers per agent. What each agent needs is
/// already a parameter of `HookInstaller`, so nothing here is a mode: it is a
/// list, and the list is what the three callers had each been keeping their own
/// version of.
enum HookSetup {

    /// Whether Codex will actually run the hooks it has registered, read from
    /// its own configuration.
    ///
    /// Only Codex has this question. Claude Code runs what is in its settings
    /// file; Codex refuses a hook it has not been approved for and **says nothing
    /// when it declines**, so "registered" and "will run" are two different
    /// facts there. See `CodexTrust`.
    static func codexTrust() -> [String: CodexTrust.State] {
        let installer = HookInstaller.codex()
        let events = installer.installedEvents()
        guard !events.isEmpty else { return [:] }
        return CodexTrust.states(
            registered: events,
            hooksFilePath: AppConfig.codexHooksURL.path,
            configuration: try? String(contentsOf: AppConfig.codexConfigURL, encoding: .utf8)
        )
    }

    /// One answer about Codex's trust, for everyone who has to say something
    /// about it. Two callers deciding this separately is how one of them came to
    /// promise that everything was approved on a machine where the file could
    /// not be read.
    static func codexTrustVerdict() -> CodexTrust.Verdict {
        CodexTrust.verdict(of: codexTrust())
    }

    /// What is true of one agent on this machine.
    enum Outcome: Equatable {
        /// The agent is not on this machine, so there is nothing to register.
        /// Writing a configuration for a program nobody has installed leaves a
        /// file that only confuses whoever finds it later.
        case notPresent
        case notInstalled
        case installed
        case failed(String)
    }

    struct Report: Equatable {
        let harness: Harness
        let outcome: Outcome
    }

    /// The agents worth talking to, in the order a person meets them.
    ///
    /// Claude Code is always here: this application is built around it and its
    /// configuration directory is created on demand. Codex is here only if its
    /// own directory is.
    static func installers(fileManager: FileManager = .default) -> [(Harness, HookInstaller)] {
        var list: [(Harness, HookInstaller)] = [(.claudeCode, HookInstaller())]
        if fileManager.fileExists(atPath: AppConfig.codexDirectory.path) {
            list.append((.codex, HookInstaller.codex()))
        }
        return list
    }

    static func state(fileManager: FileManager = .default) -> [Report] {
        var reports = installers(fileManager: fileManager).map {
            Report(harness: $0.0, outcome: $0.1.isInstalled() ? .installed : .notInstalled)
        }
        if !reports.contains(where: { $0.harness == .codex }) {
            reports.append(Report(harness: .codex, outcome: .notPresent))
        }
        return reports
    }

    /// The agents that are here and have no hooks registered, by name.
    ///
    /// What the menu puts in brackets. One line for two agents was the choice —
    /// a second entry in an already long menu costs more than it explains — so
    /// the line says which one is missing instead of making you go and look.
    static func missingNames(fileManager: FileManager = .default) -> [String] {
        state(fileManager: fileManager)
            .filter { $0.outcome == .notInstalled }
            .map(\.harness.displayName)
    }

    /// `true` when at least one agent that is here has no hooks registered.
    ///
    /// What the first-run offer asks, and what decides whether the menu says
    /// install or remove. An agent that is not on the machine is not missing.
    static func needsInstalling(fileManager: FileManager = .default) -> Bool {
        state(fileManager: fileManager).contains { $0.outcome == .notInstalled }
    }

    /// Brings every installed harness's hooks up to `token`, and writes nothing
    /// where there is nothing to change.
    ///
    /// Run at launch, after the token is settled and before the server starts
    /// answering. It is what makes requiring a token on `POST /signal` a decision
    /// this app can carry out rather than one that waits on other people
    /// reinstalling. Each installer decides for itself whether the hooks it finds
    /// are addressed to this instance — see `HookInstaller.repairToken`.
    static func repairTokens(port: UInt16 = AppConfig.listenPort, token: String?) {
        for (_, installer) in installers() {
            installer.repairToken(port: port, token: token)
        }
    }

    /// - Parameter includeMessageDelivery: Claude Code only, and refused for
    ///   Codex rather than silently ignored: it rides a second `Stop` hook that
    ///   answers a mailbox, and Codex has no way back into a session to answer
    ///   through. See `HookInstaller.codex()`.
    static func install(
        port: UInt16 = AppConfig.listenPort,
        includeToolEvents: Bool = false,
        includeMessageDelivery: Bool = false,
        fileManager: FileManager = .default
    ) -> [Report] {
        installers(fileManager: fileManager).map { harness, installer in
            do {
                // Every agent is attempted, whatever the one before it did. A
                // failure on one is not a reason to leave the other unregistered,
                // and one working while the other does not is a state a person
                // has to be able to see rather than guess at.
                _ = try installer.install(
                    port: port,
                    includeToolEvents: includeToolEvents,
                    includeMessageDelivery: includeMessageDelivery && harness == .claudeCode
                )
                return Report(harness: harness, outcome: .installed)
            } catch {
                return Report(harness: harness, outcome: .failed(error.localizedDescription))
            }
        }
    }

    static func remove(fileManager: FileManager = .default) -> [Report] {
        installers(fileManager: fileManager).map { harness, installer in
            do {
                _ = try installer.uninstall()
                return Report(harness: harness, outcome: .notInstalled)
            } catch {
                return Report(harness: harness, outcome: .failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Saying it

    /// One line per agent, for an alert or the terminal.
    static func summary(of reports: [Report]) -> String {
        reports.map { report in
            switch report.outcome {
            case .notPresent: return "\(report.harness.displayName): not on this machine"
            case .notInstalled: return "\(report.harness.displayName): no hooks registered"
            case .installed: return "\(report.harness.displayName): hooks registered"
            case .failed(let reason): return "\(report.harness.displayName): not installed, \(reason)"
            }
        }.joined(separator: "\n")
    }

    /// `true` when something that was attempted did not work.
    ///
    /// The command line used to answer 0 whether or not Codex had failed, so a
    /// script that installed the hooks and checked the exit code was told
    /// everything was fine. It is a separate answer from "nothing to do":
    /// an agent that is not here failed at nothing.
    static func hasFailure(in reports: [Report]) -> Bool {
        reports.contains { if case .failed = $0.outcome { return true } else { return false } }
    }
}
