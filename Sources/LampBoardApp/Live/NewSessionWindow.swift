import AppKit
import LampBoardCore
import SwiftUI

/// «New session…» (D133): a machine, a folder, a name, the account it signs in
/// with (D187), and the session opens in
/// the Hub (hub-terminale R4). It starts inside tmux, on this Mac or on another
/// machine, where it outlives the window; on this Mac without tmux, in the background.
@MainActor
final class NewSessionWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let store: StateStore
    private let preferences: Preferences
    private let start: (_ host: String?, _ folder: String, _ name: String?, _ permissions: NewSession.Permissions,
                        _ account: NewSession.Account?) -> Void

    init(store: StateStore, preferences: Preferences,
         start: @escaping (_ host: String?, _ folder: String, _ name: String?, _ permissions: NewSession.Permissions,
                           _ account: NewSession.Account?) -> Void) {
        self.store = store
        self.preferences = preferences
        self.start = start
    }

    func show(host: String? = nil, folder: String? = nil) {
        // Asked again while open: what was typed stays.
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosts = preferences.remoteHosts
        let model = NewSessionModel(store: store, hosts: hosts, host: host.flatMap { hosts.contains($0) ? $0 : nil }, folder: folder)
        let settings = preferences.sessionPermissions
        model.skipsPermissions = settings == .bypass
        let view = NewSessionView(model: model) { [weak self] host, folder, name, skipping, account in
            self?.window?.close()
            self?.start(host, folder, name, NewSession.Permissions.chosen(skipping: skipping, settings: settings), account)
        } cancel: { [weak self] in
            self?.window?.close()
        }
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "New session"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        if self.window == nil { window.center() }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class NewSessionModel: ObservableObject {
    /// `""` is this Mac.
    @Published var host: String {
        didSet {
            recent = NewSession.recentFolders(in: store.state, host: isRemote ? host : nil)
            folder = recent.first ?? ""
        }
    }
    @Published var folder: String {
        didSet {
            // A name typed by hand stays; one LampBoard suggested follows the folder.
            if name == suggested { name = suggestion() }
            suggested = suggestion()
        }
    }
    @Published var name = ""
    /// Skip permissions for this one start (D185); Settings' choice to begin with.
    @Published var skipsPermissions = false
    /// The account it signs in with (D187), by folder; `""` is the default.
    @Published var account = ""
    @Published private(set) var recent: [String]
    let hosts: [String]
    /// This Mac's accounts: those of another machine are taken to be named alike,
    /// and its start says so when one is not there.
    let accounts = NewSession.Account.found(in: AppConfig.homeDirectory.path)
    private let store: StateStore
    private var suggested = ""

    init(store: StateStore, hosts: [String], host: String?, folder: String?) {
        self.store = store
        self.hosts = hosts
        self.host = host ?? ""
        let recent = NewSession.recentFolders(in: store.state, host: host)
        self.recent = recent
        self.folder = folder ?? recent.first ?? ""
        suggested = suggestion()
        name = suggested
    }

    var isRemote: Bool { !host.isEmpty }

    private func suggestion() -> String {
        folder.isEmpty ? "" : (isRemote ? NewSession.tmuxName(for: folder, taken: []) : (folder as NSString).lastPathComponent)
    }

    /// What Start may run with: an absolute folder (on this Mac, one that
    /// exists), and on another machine a name tmux can take (a typed one is
    /// made into one; that machine checks its folder itself).
    var ready: (host: String?, folder: String, name: String?)? {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        guard folder.hasPrefix("/"), folder != "/" else { return nil }
        let typed = name.trimmingCharacters(in: .whitespaces)
        if isRemote { return (host, folder, NewSession.tmuxName(for: "/" + (typed.isEmpty ? folder : typed), taken: [])) }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return (nil, folder, typed.isEmpty ? nil : typed)
    }
}

struct NewSessionView: View {
    @ObservedObject var model: NewSessionModel
    let start: (String?, String, String?, Bool, NewSession.Account?) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Where", selection: $model.host) {
                Text("This Mac").tag("")
                ForEach(model.hosts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Text(model.isRemote
                 ? "It starts inside tmux on \(model.host), in its own terminal in the Hub: it keeps running when you close it, and any terminal can attach to it."
                 : "It starts inside tmux on this Mac, in its own terminal in the Hub: it keeps running when you close it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Folder").font(.headline)
            if model.recent.isEmpty {
                Text("No sessions there yet: type the folder below.").font(.callout).foregroundStyle(.secondary)
            } else {
                List(model.recent, id: \.self, selection: Binding(get: { model.folder }, set: { model.folder = $0 ?? "" })) { path in
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(path)
                }
                .frame(minHeight: 140)
            }
            HStack {
                TextField("/path/to/project", text: $model.folder).textFieldStyle(.roundedBorder)
                if !model.isRemote {
                    Button("Choose…") { choose() }
                }
            }
            HStack {
                Text("Name").font(.headline)
                TextField(model.isRemote ? "tmux session" : "optional", text: $model.name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 3) {
                Picker("Account", selection: $model.account) {
                    Text("Default (~/.claude)").tag("")
                    ForEach(model.accounts, id: \.folder) { Text($0.name).tag($0.folder) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("newSession.account")
                Text(model.accounts.isEmpty
                     ? "One Claude Code account here. To add one: Scripts/claude-account.sh add <name>, then sign in."
                     : "The Claude Code account this session signs in with, from its own folder ~/.claude-<name>.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Skip permissions", isOn: $model.skipsPermissions)
                    .accessibilityIdentifier("newSession.skipPermissions")
                Text("Claude Code runs any command and edits any file without asking. Only this session; Settings › Acting from the panel keeps the rest.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Start") {
                    if let ready = model.ready {
                        start(ready.host, ready.folder, ready.name, model.skipsPermissions, NewSession.Account(folder: model.account))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.ready == nil)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.folder = url.path }
    }
}
