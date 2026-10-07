import LampBoardCore
import SwiftUI

/// Settings › Other Macs: the machines whose sessions reach the panel through an
/// ssh tunnel this app opens and keeps open (D83, U3).
struct OtherMacsPane: View {
    @ObservedObject var fleet: RemoteFleet

    @State private var newHost = ""
    @State private var addError: String?
    /// The machine whose hooks are about to be installed; the alert asks first,
    /// because this writes a file on another computer.
    @State private var installTarget: String?

    var body: some View {
        SettingsGroupBox(title: SettingsCatalog.section(of: .otherMacs).groups[0].title) {
            SettingRow(id: .otherMacs) { EmptyView() }

            if fleet.hosts.isEmpty {
                Text("No machines yet.").foregroundStyle(.secondary)
            }
            ForEach(fleet.hosts, id: \.self) { host in
                hostRow(host)
            }
            HStack {
                TextField("name as ssh knows it: node, or user@host", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newHost.trimmed.isEmpty)
            }
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            Text("""
            A machine's sessions appear when they speak, because their hooks reach this Mac \
            through the tunnel, and leave when the machine says the process is gone. \
            Clicking one raises its Remote-SSH window here, if one is open.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .alert(
            "Connect \(installTarget ?? "")?",
            isPresented: Binding(get: { installTarget != nil }, set: { if !$0 { installTarget = nil } })
        ) {
            Button("Connect") {
                if let host = installTarget { fleet.run(.install, on: host) }
                installTarget = nil
            }
            Button("Cancel", role: .cancel) { installTarget = nil }
        } message: {
            Text(
                "LampBoard will write ~/.lampboard/hook.sh and register "
                + "\(HookConfigMerger.defaultEvents.count) hooks in ~/.claude/settings.json on "
                + "\(installTarget ?? "that machine"), over ssh. A dated backup of that file is left there, "
                + "and nothing is written if the file changes in the meantime. The panel can show that "
                + "machine's sessions; it cannot answer them."
            )
        }
    }

    private func add() {
        addError = fleet.add(newHost)
        if addError == nil { newHost = "" }
    }

    private func hostRow(_ host: String) -> some View {
        let status = fleet.status[host] ?? RemoteHostStatus()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(host).font(.headline)
                if status.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Check", action: { fleet.run(.check, on: host) })
                if status.hooks == .installed {
                    Button("Disconnect", action: { fleet.run(.uninstall, on: host) })
                } else {
                    Button("Connect…", action: { installTarget = host })
                }
                Button(action: { fleet.remove(host) }) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Forget this machine. Its connection stays until you disconnect it.")
            }
            .disabled(status.busy)

            HStack(spacing: 14) {
                Label(status.tunnel.label, systemImage: tunnelSymbol(status.tunnel))
                Label(status.hooks.label, systemImage: hooksSymbol(status.hooks))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let message = status.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func tunnelSymbol(_ state: RemoteTunnel.State) -> String {
        switch state {
        case .up: return "link"
        case .starting: return "ellipsis.circle"
        case .down: return "exclamationmark.triangle"
        case .exposed: return "exclamationmark.shield"
        case .stopped: return "link.badge.plus"
        }
    }

    private func hooksSymbol(_ hooks: RemoteHostStatus.Hooks) -> String {
        switch hooks {
        case .installed: return "checkmark.circle"
        case .absent: return "circle"
        case .checking, .unknown: return "questionmark.circle"
        case .failed: return "xmark.circle"
        }
    }
}
