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
                    Text((source.root as NSString).lastPathComponent).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if source.isRemote { Text("R").font(.system(size: 9, weight: .bold)).padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25))) }
                    Spacer()
                }
                TextField("Search the project…", text: $files.query)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .accessibilityIdentifier("hub.files.search")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if files.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                            ForEach(Array(files.hits.enumerated()), id: \.offset) { _, hit in hitRow(hit) }
                            if files.hits.isEmpty { Text("Nothing found.").font(.system(size: 11)).foregroundStyle(.secondary) }
                        } else {
                            tree(nil, depth: 0)
                        }
                    }
                }
                legend(remote: source.isRemote)
            } else {
                Spacer()
                Text("No project folder for this session.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .frame(minWidth: 200, maxHeight: .infinity, alignment: .top)
    }

    private func tree(_ folder: String?, depth: Int) -> AnyView {
        AnyView(ForEach(files.entries(in: folder)) { entry in
            let path = folder.map { "\($0)/\(entry.name)" } ?? entry.name
            VStack(alignment: .leading, spacing: 1) {
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
                Image(systemName: entry.isFolder ? (files.expanded.contains(path) ? "chevron.down" : "chevron.right") : "doc")
                    .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 10)
                Text(entry.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(color(of: path))
                Spacer(minLength: 4)
                if let code = files.git[path] {
                    Text(code).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 4).fill(files.active == path ? Color.accentColor.opacity(0.18) : .clear))
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: "@\(path)" as NSString) }
        .help(entry.isFolder ? path : "\(path) · click to open, drag into the message to cite it")
        .accessibilityIdentifier("hub.file.\(path)")
    }

    private func hitRow(_ hit: SearchHits.Hit) -> some View {
        Button { files.openFile(hit.path) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(hit.path):\(hit.line)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(hit.text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: "@\(hit.path)" as NSString) }
    }

    private func color(of path: String) -> Color {
        switch files.marks[path] {
        case .read: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .written: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .committed: return Color(red: 0.3, green: 0.75, blue: 0.45)
        case nil: return .primary
        }
    }

    private func legend(remote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Label("read", systemImage: "circle.fill").foregroundStyle(color(read: .read))
                Label("written", systemImage: "circle.fill").foregroundStyle(color(read: .written))
                Label("in a commit", systemImage: "circle.fill").foregroundStyle(color(read: .committed))
            }
            Text(remote ? "Read through LampBoard's ssh, inside the project only" : "Read from this Mac's disk")
        }
        .font(.system(size: 10)).labelStyle(.titleAndIcon).foregroundStyle(.secondary)
    }

    private func color(read mark: FileMarks.Mark) -> Color {
        switch mark {
        case .read: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .written: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .committed: return Color(red: 0.3, green: 0.75, blue: 0.45)
        }
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
                Text("Open a file from the project's tree.").foregroundStyle(.secondary)
                Spacer()
            } else {
                tabs
                Divider()
                if let file = files.activeFile { content(file) }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(files.open) { file in
                    HStack(spacing: 4) {
                        Text(file.name).font(.system(size: 11, design: .monospaced))
                        Button { files.close(file.path) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain).help("Close \(file.name)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(files.active == file.path ? Color.secondary.opacity(0.2) : .clear))
                    .onTapGesture { files.active = file.path }
                }
            }
            .padding(4)
        }
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
                .pickerStyle(.segmented).fixedSize().accessibilityIdentifier("hub.viewer.mode")
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
