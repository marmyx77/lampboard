import Combine
import LampBoardCore
import SwiftUI

/// The helper (the companion mod) in Settings › Claude Code & Codex: the switch,
/// what it does said before it is pressed, and Claude Code's own reading of it on
/// request (5.10). Answering from the panel and the line above each prompt, which
/// need it, have their own places since 1.1 (U3).
///
/// Off until switched on, like LampMaster: the mod runs inside every session
/// somebody opens, and that is theirs to agree to, having read what it does.
struct ModSettings: View {
    @State private var installed = false
    @State private var installedVersion: String?
    @State private var working = false
    @State private var problem: String?
    @State private var reading: ModTrust.Reading?
    /// Getting started, the command line or the launch refresh can change it
    /// while this window is open: read again every few seconds.
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingToggle(id: .helper, isOn: installed, enabled: !working) { wanted in Task { await set(wanted) } }

            Text("""
            Claude Code 2.1.287 and later run small plugins inside each session. The helper tells \
            this panel each session's exact context, its cost, your plan's limits, the tool it is \
            running and why a turn ended. Of a running tool it reads the name and the first line of \
            its command (anything that looks like a secret masked) or its file path — never a \
            conversation, never a file's contents — and it talks only to this Mac. It never runs a \
            tool or writes a file itself. It can make Claude Code ask you first: before an edit to a \
            file another session has just written, and, while you are away, before a destructive \
            command. With the switches under Acting from the panel, it carries your answers to \
            permissions and questions. Sessions already open pick it up after a restart.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if installed, let installedVersion, installedVersion != ModFiles.version {
                Text("Installed: \(installedVersion). This app carries \(ModFiles.version); it is updated at the next launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let reading {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reading.valid ? "Version \(ModFiles.version), as Claude Code reads it:"
                                       : "Claude Code does not accept version \(ModFiles.version):")
                        .font(.callout.weight(.medium))
                    ForEach(reading.sentences + reading.problems, id: \.self) { line in
                        Text("· " + line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button(reading == nil ? "Ask Claude Code what it does" : "Ask again") { Task { await describe() } }
                .disabled(working)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in if !working { reload() } }
    }

    private func reload() {
        installed = ModSetup.isInstalled
        installedVersion = ModSetup.installedVersion
        if problem == nil { problem = ModSetup.lastProblem }
    }

    /// `claude plugin` runs off the main thread: up to four processes, and the
    /// Settings window must not freeze while they start.
    private func set(_ wanted: Bool) async {
        working = true
        let outcome = await Task.detached { wanted ? ModSetup.install() : ModSetup.uninstall() }.value
        if case .failed(let reason) = outcome { problem = reason } else { problem = nil }
        working = false
        reload()
    }

    private func describe() async {
        working = true
        switch await Task.detached(operation: { ModSetup.describe() }).value {
        case .success(let result): reading = result; problem = nil
        case .failure(let failure): problem = failure.reason
        }
        working = false
    }
}
