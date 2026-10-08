import AppKit
import LampBoardCore
import SwiftUI

/// «New session…» (D133): a machine, a folder, a name, and the session opens in
/// the live view. On this Mac it starts in the background; on another machine it
/// starts inside tmux, where it outlives the window.
@MainActor
final class NewSessionWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let store: StateStore
    private let preferences: Preferences
    private let start: (_ host: String?, _ folder: String, _ name: String?) -> Void

    init(store: StateStore, preferences: Preferences,
         start: @escaping (_ host: String?, _ folder: String, _ name: String?) -> Void) {
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
        let view = NewSessionView(model: model) { [weak self] host, folder, name in
            self?.window?.close()
            self?.start(host, folder, name)
        } cancel: { [weak self] in
            self?.window?.close()
        }
        let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
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
    @Published private(set) var recent: [String]
    let hosts: [String]
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
    let start: (String?, String, String?) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Where", selection: $model.host) {
                Text("This Mac").tag("")
                ForEach(model.hosts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Text(model.isRemote
                 ? "It starts inside tmux on \(model.host): it keeps running when you close the window, and any terminal can attach to it."
                 : "It starts in the background on this Mac: it keeps running when you close the window.")
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
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Start") {
                    if let ready = model.ready { start(ready.host, ready.folder, ready.name) }
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
