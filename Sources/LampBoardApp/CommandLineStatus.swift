import LampBoardCore
import Foundation

/// `lampboard status`: what this machine can see, and what it cannot.
///
/// Split out of `CommandLineInterface` at the 800-line ceiling, and along a seam
/// that was already there: everything else in that file **does** something — it
/// installs, it raises a window, it opens a conversation — and this one only
/// looks and reports. It is also the longest single command, because reporting
/// honestly means naming the difference between "none" and "could not be read"
/// every time it comes up.
extension CommandLineInterface {

    static func runStatus() -> Int32 {
        let installer = HookInstaller()
        let events = installer.installedEvents()

        print("Claude Code")
        // Read, not assumed, because the hooks' shape depends on it (D49). "Not
        // found" is a different fact from an old version, and the installer
        // treats the first as current.
        let version = ClaudeCodeInstallation.installedVersion()
        print("  Version:      \(version.map(String.init(describing:)) ?? "not found, taken as current")")
        if let note = NativeHookSupport.note(for: version) { print("                \(note)") }
        print("  Hook script:  \(installer.scriptPath)")
        print("  Registered:   \(events.isEmpty ? "no" : events.joined(separator: ", "))")

        // Reported separately, because the two are separately installable and one
        // of them can be missing while the other is fine. A single line saying
        // "hooks installed" was true and useless on a machine where Codex was not.
        print()
        print("Codex")
        if FileManager.default.fileExists(atPath: AppConfig.codexDirectory.path) {
            let codex = HookInstaller.codex()
            let codexEvents = codex.installedEvents()
            print("  Hook script:  \(codex.scriptPath)")
            print("  Registered:   \(codexEvents.isEmpty ? "no" : codexEvents.joined(separator: ", "))")
            if !codexEvents.isEmpty {
                // Codex records which hooks it has been told to trust, and it
                // refuses the rest in silence: registered and will-run are two
                // different facts here, and this used to say the second one was
                // unknowable. It is not — see `CodexTrust`.
                switch HookSetup.codexTrustVerdict() {
                case .unreadable:
                    print("  Trust:        \(AppConfig.codexConfigURL.path) could not be read")
                case .allApproved:
                    print("  Trust:        every registered hook has been approved")
                case .waiting(let events):
                    print("  Trust:        NOT APPROVED, so these stay silent: "
                        + events.joined(separator: ", "))
                    print("                run /hooks inside Codex and approve them")
                }
            }
            switch CodexProcessScanner().scan() {
            case .unavailable(let reason):
                // Told apart from "none", because they are different facts and the
                // second one is a reason to go looking.
                print("  Live sessions: could not be read (\(reason))")
            case .observed(let evidence) where evidence.isEmpty:
                print("  Live sessions: none holding a rollout open")
            case .observed(let evidence):
                print("  Live sessions: \(evidence.count)")
                for item in evidence {
                    print("    · \(item.meta.cwd)  [\(item.surface.label)]")
                }
            }
        } else {
            print("  Not installed on this machine (\(AppConfig.codexDirectory.path) is not there)")
        }
        print()

        let now = Date()
        let windows = IDEWindowReader().readWindows()
        let fresh = windows.filter { $0.isSupported }
        print("VS Code windows with Claude Code active: \(fresh.count)")
        for window in fresh {
            for folder in window.workspaceFolders {
                print("  · \(folder)")
            }
        }

        let live = LiveSessionReader().readLiveSessions()
        let hosted = live.filter(\.deservesTrafficLight)
        let resolved = hosted.filter {
            WorkspaceResolver.resolve(cwd: $0.cwd, in: windows, at: now) != nil
        }
        print()
        print("Claude Code sessions with a live process: \(live.count)")
        print("  of which inside VS Code:                \(hosted.count)")
        print("  of which with a recognized workspace:   \(resolved.count)  ← rows in the column")
        if hosted.count > resolved.count {
            print("  The others have a cwd that no lock in ~/.claude/ide/ contains.")
        }

        reportRemoteHosts()
        print("Accessibility permission: \(VSCodeFocuser.hasAccessibilityPermission ? "granted" : "MISSING")")

        let automation = VSCodeFocuser.checkAutomationPermission()
        print("Automation permission:    \(automation == nil ? "granted" : "MISSING")")
        if let automation {
            print("  \(automation.shortDescription)")
        }

        // Read the permissions above with a grain of salt: run from a terminal,
        // this command answers for the **responsible process** — the shell — and
        // not for the app. Treat it as a hint, not as proof; the proof is in the
        // log of the app started with LAMPBOARD_DEBUG=1.
        printOptionalFeatures()
        return 0
    }
}
