import Combine
import LampBoardCore
import SwiftUI

/// The companion mod's section of Settings: the switch, what the mod does said
/// before it is pressed, and Claude Code's own reading of it on request (5.10).
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
        Section {
            Toggle("Install the LampBoard mod in Claude Code", isOn: Binding(
                get: { installed },
                set: { wanted in Task { await set(wanted) } }
            ))
            .disabled(working)

            Text("""
            Claude Code 2.1.287 and later run small plugins inside each session. LampBoard's \
            tells this panel each session's context as Claude Code counts it, what the session \
            has cost, your plan's limits, which tool it is running and why it ended. It reads \
            LampBoard's token and port, and of a running tool its name and the first line of \
            its shell command (anything that looks like a secret masked) or its file path — \
            no conversation, no file's contents — writes nothing, runs nothing, \
            and talks only to 127.0.0.1, once that port answers as \
            LampBoard. It adds nothing to the context of your sessions. Sessions already open \
            pick it up after a restart.
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
        } header: {
            Text("The LampBoard mod")
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
