import AppKit
import ClarcChatKit
import LampBoardCore
import SwiftUI

/// The third column: the project's tree, a search, and what each file is to
/// git and to the session (D156). A click opens the file in the last column; a
/// drag carries `@path` for the composer.
struct HubFilesView: View {
    @ObservedObject var files: HubFilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = files.source {
                HStack(spacing: 6) {
                    Text((source.root as NSString).lastPathComponent.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).kerning(0.8)
                        .foregroundStyle(HubPalette.muted).lineLimit(1)
                    if source.isRemote {
                        Text("R").font(.system(size: 9, weight: .bold)).padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 3).fill(HubPalette.line))
                    }
                    Spacer()
                }
                .padding(.top, 2)
                TextField("Search a file…", text: $files.query)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(HubPalette.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(HubPalette.line))
                    .accessibilityIdentifier("hub.files.search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if files.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                            ForEach(Array(files.hits.enumerated()), id: \.offset) { _, hit in hitRow(hit) }
                            if files.hits.isEmpty { Text("Nothing found.").font(.system(size: 11)).foregroundStyle(HubPalette.muted) }
                        } else {
                            tree(nil, depth: 0)
                        }
                    }
                }
                legend(remote: source.isRemote)
            } else {
                Spacer()
                Text("No project folder for this session.").font(.system(size: 11)).foregroundStyle(HubPalette.muted)
                Spacer()
            }
        }
        .padding(10)
        .frame(minWidth: 200, maxHeight: .infinity, alignment: .top)
        .background(HubPalette.soft.ignoresSafeArea())
        .foregroundStyle(HubPalette.ink)
    }

    private func tree(_ folder: String?, depth: Int) -> AnyView {
        AnyView(ForEach(files.entries(in: folder)) { entry in
            let path = folder.map { "\($0)/\(entry.name)" } ?? entry.name
            VStack(alignment: .leading, spacing: 0) {
                row(entry, path: path, depth: depth)
                if entry.isFolder, files.expanded.contains(path) { tree(path, depth: depth + 1) }
            }
        })
    }

    private func row(_ entry: ProjectSource.Entry, path: String, depth: Int) -> some View {
        Button {
            if entry.isFolder { files.toggle(path) } else { files.openFile(path) }
        } label: {
            HStack(spacing: 5) {
                Text(entry.isFolder ? (files.expanded.contains(path) ? "▾" : "▸") : "·")
                    .font(HubPalette.monoSmall).foregroundStyle(HubPalette.muted).frame(width: 9)
                Text(entry.isFolder ? entry.name + "/" : entry.name).font(HubPalette.mono).lineLimit(1)
                    .foregroundStyle(color(of: path))
                Spacer(minLength: 4)
                if let code = files.git[path] {
                    Text(code).font(HubPalette.monoSmall).foregroundStyle(HubPalette.muted)
                }
            }
            .padding(.leading, CGFloat(depth) * 10 + 2)
            .padding(.vertical, 2).padding(.trailing, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 4).fill(files.active == path ? HubPalette.accentSoft : .clear))
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: "@\(path)" as NSString) }
        .help(entry.isFolder ? path : "\(path) · click to open, drag into the message to cite it")
        .accessibilityIdentifier("hub.file.\(path)")
    }

    private func hitRow(_ hit: SearchHits.Hit) -> some View {
        Button { files.openFile(hit.path) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(hit.path):\(hit.line)").font(HubPalette.monoSmall).foregroundStyle(HubPalette.muted)
                Text(hit.text).font(HubPalette.monoSmall).lineLimit(1)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: "@\(hit.path)" as NSString) }
    }

    private func color(of path: String) -> Color {
        switch files.marks[path] {
        case .read: return HubPalette.read
        case .written: return HubPalette.amber
        case .committed: return HubPalette.green
        case nil: return HubPalette.ink
        }
    }

    private func legend(remote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                dot(HubPalette.read, "read")
                dot(HubPalette.amber, "written")
                dot(HubPalette.green, "in a commit")
            }
            Text("Click: opens on the right · drag into the message: cites it")
            Text(remote ? "Read through LampBoard's ssh, inside the project only" : "Read from this Mac's disk")
        }
        .font(.system(size: 10)).foregroundStyle(HubPalette.muted)
    }

    private func dot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 6, height: 6); Text(label) }
    }
}

/// The last column's file: tabs, the path and what git says, Code or Preview
/// for Markdown, the code highlighted with line numbers (D156).
struct HubViewerView: View {
    @ObservedObject var files: HubFilesModel
    /// The most lines drawn: a generated file of a hundred thousand must not hold the Hub.
    static let mostLines = 4000

    var body: some View {
        VStack(spacing: 0) {
            if files.open.isEmpty {
                Spacer()
                Text("No file open. Open one from the project's files with the folder icon above.")
                    .font(.system(size: 12)).foregroundStyle(HubPalette.muted).multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                tabs
                Divider()
                if let file = files.activeFile { content(file) }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        .background(HubPalette.panel)
        .foregroundStyle(HubPalette.ink)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(files.open) { file in
                    HStack(spacing: 4) {
                        Text(file.name).font(HubPalette.monoSmall)
                        Button { files.close(file.path) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain).help("Close \(file.name)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(files.active == file.path ? HubPalette.panel : .clear))
                    .foregroundStyle(files.active == file.path ? HubPalette.ink : HubPalette.muted)
                    .onTapGesture { files.active = file.path }
                }
            }
            .padding(4)
        }
        .background(HubPalette.soft)
    }

    @ViewBuilder private func content(_ file: HubFilesModel.OpenFile) -> some View {
        HStack(spacing: 8) {
            Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if let code = files.git[file.path] { Text(code).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.orange) }
            Spacer()
            if file.kind == .markdown {
                Picker("View", selection: Binding(
                    get: { files.previews.contains(file.path) },
                    set: { if $0 { files.previews.insert(file.path) } else { files.previews.remove(file.path) } }
                )) {
                    Text("Code").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityIdentifier("hub.viewer.mode")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider()
        switch file.kind {
        case .binary:
            note("Not text: open it with its own app.")
        case .markdown where files.previews.contains(file.path):
            ScrollView { MarkdownContentView(text: file.text ?? "").padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        case .markdown, .code:
            if let text = file.text { code(text, language: language(of: file)) } else { note("Reading…") }
        }
    }

    private func language(of file: HubFilesModel.OpenFile) -> String {
        if case .code(let language) = file.kind { return language }
        return "md"
    }

    private func code(_ text: String, language: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(Self.mostLines).joined(separator: "\n")
        return ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 10) {
                Text((1...max(1, min(lines.count, Self.mostLines))).map(String.init).joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Text(SyntaxHighlighter.highlight(shown, language: language, fontSize: 12)).textSelection(.enabled)
            }
            .padding(10)
            if lines.count > Self.mostLines {
                note("Showing the first \(Self.mostLines) of \(lines.count) lines.")
            }
        }
        .accessibilityIdentifier("hub.viewer.code")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding()
    }
}
