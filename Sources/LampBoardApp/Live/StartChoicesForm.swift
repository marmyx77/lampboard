import LampBoardCore
import SwiftUI

/// What a form chooses for a start (D188), the same three wherever a session
/// starts from a form: New session, Attach a project, Resume.
struct StartChoices: Equatable {
    /// In tmux, where it outlives the Hub; else it ends when its terminal closes (D168).
    var keepsRunning = true
    /// No permission asked, for this one (D185).
    var skipping = false
    /// The account's folder, `""` for the default (D187).
    var account = ""

    /// Settings' choice to begin with: skipping when Settings skips.
    init(settings: NewSession.Permissions) { skipping = settings == .bypass }

    func permissions(settings: NewSession.Permissions) -> NewSession.Permissions {
        NewSession.Permissions.chosen(skipping: skipping, settings: settings)
    }

    var chosenAccount: NewSession.Account? { NewSession.Account(folder: account) }

    func plan(_ kind: StartPlan.Kind = .new) -> StartPlan {
        StartPlan(kind: kind, keepsRunning: keepsRunning, skipping: skipping, account: chosenAccount)
    }
}

/// The three choices, drawn alike in every form that starts a session (D188).
struct StartChoicesForm: View {
    @Binding var choices: StartChoices
    /// The machine it starts on, for the words; `nil` is this Mac.
    let host: String?
    /// This Mac's accounts: another machine's are taken to be named alike, and
    /// its start says so when one is not there (D187).
    let accounts = NewSession.Account.found(in: AppConfig.homeDirectory.path)
    /// The identifiers' prefix, for the tests' real hands.
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Picker("When closed", selection: $choices.keepsRunning) {
                    Text("Keeps running").tag(true)
                    Text("Ends").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("\(id).keepsRunning")
                Text(choices.keepsRunning
                     ? "It starts inside tmux\(host.map { " on \($0)" } ?? " on this Mac"), in its own terminal in the Hub: it keeps running when you close it."
                     : "It runs in its own terminal in the Hub, and ends when you close that terminal or quit LampBoard.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Picker("Account", selection: $choices.account) {
                    Text("Default (~/.claude)").tag("")
                    ForEach(accounts, id: \.folder) { Text($0.name).tag($0.folder) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("\(id).account")
                Text(accounts.isEmpty
                     ? "One Claude Code account here. To add one: Scripts/claude-account.sh add <name>, then sign in."
                     : "The Claude Code account it signs in with, from its own folder ~/.claude-<name>\(host.map { " on \($0)" } ?? "").")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Skip permissions", isOn: $choices.skipping)
                    .accessibilityIdentifier("\(id).skipPermissions")
                Text("Claude Code runs any command and edits any file without asking. Only this session; Settings › Acting from the panel keeps the rest.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// «Browse…» on another machine: one level of its folders at a time, up, and
/// «Use this folder». Shared by Attach a project and New session (D188).
struct RemoteFolderBrowser: View {
    let host: String
    @Binding var path: String
    /// The identifiers' prefix, for the tests' real hands.
    let id: String
    @State private var listing: RemoteFolders.Listing?
    @State private var unreachable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if unreachable {
                Text("\(host) did not answer, or that folder is not there.").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let listing {
                HStack {
                    Text(listing.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Use this folder") { path = listing.path }
                        .accessibilityIdentifier("\(id).useFolder")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let parent = listing.parent {
                            folderRow("..", symbol: "arrow.turn.left.up") { open(parent) }
                        }
                        ForEach(listing.folders, id: \.self) { name in
                            folderRow(name, symbol: "folder") { open(listing.child(name)) }
                        }
                    }
                }
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } else if !unreachable {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: host) { open(path.hasPrefix("/") ? path : nil) }
    }

    private func folderRow(_ name: String, symbol: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(id).folder.\(name)")
    }

    private func open(_ folder: String?) {
        let machine = host
        unreachable = false
        Task {
            let answer = await ProjectSource.browse(host: machine, path: folder)
            guard machine == host else { return }
            listing = answer ?? listing
            unreachable = answer == nil
            if let answer { path = answer.path }
        }
    }
}
