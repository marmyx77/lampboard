import LampBoardCore
import SwiftUI

/// The Settings window's content: LampMaster, the companion mod, then the
/// remote machines, as one form.
struct SettingsView: View {
    @ObservedObject var fleet: RemoteFleet
    let lampMaster: LampMasterService
    var preferences = Preferences()

    @State private var showsTerminalSessions = Preferences().showsTerminalSessions
    @State private var newHost = ""
    @State private var addError: String?
    /// The machine whose hooks are about to be installed; the alert asks first,
    /// because this writes a file on another computer.
    @State private var installTarget: String?

    var body: some View {
        Form {
            LampMasterSettings(service: lampMaster)
            ModSettings()
            Section {
                Text("""
                Sessions running on another machine reach the panel through an ssh \
                tunnel this app opens and keeps open: a loopback port of your own over \
                there, checked after every connect to be bound to nothing else. The machine \
                needs ssh key login (no password prompt), python3 and curl. Add it, then \
                install the hooks there.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
            } header: {
                Text("Remote machines")
            } footer: {
                Text("""
                A machine's sessions appear when they speak, because their hooks reach this Mac \
                through the tunnel, and leave when the machine says the process is gone. \
                Clicking one raises its Remote-SSH window here, if one is open.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show terminal sessions", isOn: $showsTerminalSessions)
                    .onChange(of: showsTerminalSessions) { _, wanted in
                        preferences.showsTerminalSessions = wanted
                    }
            } header: {
                Text("Terminal sessions")
            } footer: {
                Text("""
                A `claude` started in a terminal (Terminal, iTerm2, Ghostty, a tmux or \
                zellij pane) in a folder no editor window has open gets a row of its own, \
                named by its conversation. The panel follows the switch within five seconds. \
                Clicking such a row will ask, once per terminal application, for the \
                Automation permission that lets the panel select its tab.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 340)
        .alert(
            "Install the hooks on \(installTarget ?? "")?",
            isPresented: Binding(get: { installTarget != nil }, set: { if !$0 { installTarget = nil } })
        ) {
            Button("Install") {
                if let host = installTarget { fleet.run(.install, on: host) }
                installTarget = nil
            }
            Button("Cancel", role: .cancel) { installTarget = nil }
        } message: {
            Text(
                "lampboard will write ~/.lampboard/hook.sh and register "
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
                    Button("Remove hooks", action: { fleet.run(.uninstall, on: host) })
                } else {
                    Button("Install hooks…", action: { installTarget = host })
                }
                Button(action: { fleet.remove(host) }) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Forget this machine. The hooks installed there stay until you remove them.")
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
