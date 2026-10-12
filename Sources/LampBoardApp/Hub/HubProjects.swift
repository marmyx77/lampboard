import AppKit
import LampBoardCore
import SwiftUI

/// The past conversations of a project, read off the main thread: on this Mac
/// from its transcripts folder, elsewhere through the panel's ssh.
enum PastConversationReader {

    nonisolated static func local(folder: String) -> [PastConversations.Item] {
        let directory = AppConfig.homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(TranscriptLocator.directoryName(forWorkspace: folder), isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let live = Set(LiveSessionReader().readLiveSessions().map(\.sessionId))
        let dated = files.filter { $0.pathExtension == "jsonl" }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        let items = dated.map { PastConversations.Item(id: $0.0.deletingPathExtension().lastPathComponent, modified: $0.1, title: nil) }
        // Titles only for the ones shown: half a megabyte read from each.
        return PastConversations.pick(items, live: live).map { item in
            let url = directory.appendingPathComponent(item.id + ".jsonl")
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: TranscriptTitleScanner.headLimit)
            }
            return PastConversations.Item(id: item.id, modified: item.modified, title: head.flatMap(TranscriptTitleScanner.title(in:)))
        }
    }

    nonisolated static func remote(folder: String, host: String, live: Set<String>) async -> [PastConversations.Item] {
        guard let listing = await ProjectSource.ssh(host, RemoteTranscripts.list()) else { return [] }
        return PastConversations.pick(PastConversations.remote(RemoteTranscripts.parse(listing), folder: folder), live: live)
    }
}

/// The projects' part of the Hub's first column (hub-terminale R3): the ones
/// attached, then the folders the sessions are in, each with what can be started
/// there.
struct HubProjectsSection: View {
    @ObservedObject var model: HubModel
    @ObservedObject var projects: ProjectStore
    @ObservedObject var store: StateStore
    @State private var adding = false
    @State private var resuming: ProjectList.Entry?
    @AppStorage("hub.projectsShown") private var shown = true

    var body: some View {
        // LampMaster's own folder is its row, not a project.
        let entries = ProjectList.entries(attached: projects.attached, state: store.state)
            .filter { $0.host != nil || $0.path != LampMasterConductor.folder.path }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { shown.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: shown ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("Projects").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(HubPalette.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { adding = true } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(HubPalette.muted)
                    .help("Attach a project, on this Mac or another machine")
                    .accessibilityIdentifier("hub.projects.add")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if shown {
                let list = VStack(alignment: .leading, spacing: 1) { ForEach(entries) { entry in row(entry) } }
                // Six fit; more scroll, in the same height, so the sessions keep their room.
                if entries.count > 6 {
                    ScrollView(.vertical) { list }.frame(height: 6 * 24)
                } else {
                    list.padding(.bottom, 4)
                }
            }
        }
        .sheet(isPresented: $adding) {
            HubAddProjectSheet(hosts: model.deps.hosts(), done: { path, host, start in
                adding = false
                guard projects.add(path: path, host: host) else {
                    return Alerts.tell(title: "This folder cannot be attached", message: "A project is an absolute folder, on this Mac or on a machine in Settings › Other Macs.")
                }
                if start { model.startSession(folder: path, host: host) }
            }, cancel: { adding = false })
        }
        .sheet(item: $resuming) { entry in
            HubResumeSheet(entry: entry, load: { await model.pastConversations(entry) }, pick: { id in
                resuming = nil
                model.resumeSession(id, folder: entry.path, host: entry.host)
            }, cancel: { resuming = nil })
        }
    }

    private func row(_ entry: ProjectList.Entry) -> some View {
        Menu {
            Button(entry.host.map { "New session on \($0)" } ?? "New session") { model.startSession(folder: entry.path, host: entry.host) }
            if entry.host == nil {
                Button("New session in the background") { model.startInBackground(folder: entry.path) }
            }
            Button("Resume a conversation…") { resuming = entry }
            Divider()
            if entry.attached {
                Button("Remove from the list") { projects.remove(entry.id) }
            } else {
                Button("Keep in the list") { projects.add(path: entry.path, host: entry.host) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.attached ? "folder.fill" : "folder").font(.system(size: 11))
                    .foregroundStyle(entry.attached ? HubPalette.accent : HubPalette.muted)
                Text(entry.name).font(.system(size: 12)).foregroundStyle(HubPalette.ink).lineLimit(1)
                if let host = entry.host {
                    Text(host).font(.system(size: 10)).foregroundStyle(HubPalette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !entry.sessionIds.isEmpty {
                    Text("\(entry.sessionIds.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(HubPalette.muted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityIdentifier("hub.project.\(entry.name)")
    }
}

/// «+»: a folder on this Mac, chosen or typed, or a path on another machine.
struct HubAddProjectSheet: View {
    let hosts: [String]
    let done: (_ path: String, _ host: String?, _ start: Bool) -> Void
    let cancel: () -> Void
    @State private var host = ""
    @State private var path = ""
    @State private var start = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach a project").font(.system(size: 15, weight: .bold))
            Picker("Where", selection: $host) {
                Text("This Mac").tag("")
                ForEach(hosts, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                TextField(host.isEmpty ? "/Users/you/project" : "/home/you/project", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("hub.addProject.path")
                if host.isEmpty { Button("Choose…", action: choose) }
            }
            Toggle("Start a session there", isOn: $start)
            Text(host.isEmpty
                 ? "Sessions start in tmux on this Mac, in their own terminal in the Hub."
                 : "Sessions start in tmux on \(host), reached over ssh, in their own terminal in the Hub.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Attach") { done(path.trimmingCharacters(in: .whitespaces), host.isEmpty ? nil : host, start) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!path.trimmingCharacters(in: .whitespaces).hasPrefix("/"))
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// «Resume a conversation…»: the project's past conversations, none that a
/// process holds now.
struct HubResumeSheet: View {
    let entry: ProjectList.Entry
    let load: () async -> [PastConversations.Item]
    let pick: (String) -> Void
    let cancel: () -> Void
    @State private var items: [PastConversations.Item]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resume in \(entry.name)\(entry.host.map { " on \($0)" } ?? "")").font(.system(size: 15, weight: .bold))
            Text("It goes on in tmux, in its own terminal in the Hub. Conversations open somewhere now are not listed: two writers would fork them.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Group {
                if let items, items.isEmpty {
                    Text("No conversation to take up here.").foregroundStyle(.secondary)
                } else if let items {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(items) { item in
                                Button { pick(item.id) } label: {
                                    HStack {
                                        Text(item.title ?? String(item.id.prefix(8))).lineLimit(1)
                                        Spacer()
                                        Text(RelativeTime.label(for: item.modified, now: Date())).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("hub.resume.\(item.id)")
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
        }
        .padding(18)
        .frame(width: 460)
        .task { items = await load() }
    }
}
