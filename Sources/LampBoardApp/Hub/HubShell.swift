import AppKit
import LampBoardCore
import SwiftUI

/// The project's shell in the last column (D156): the person's own shell in the
/// project's folder, or ssh with a terminal into it on another machine. One per
/// project, kept while the Hub is open, so moving between sessions loses none.
/// A shell and not the session: nothing typed here reaches the conversation.
@MainActor
final class HubShells {

    private var surfaces: [String: SwiftTermSurface] = [:]

    func surface(root: String, host: String?) -> SwiftTermSurface {
        let key = (host ?? "") + "\u{0}" + root
        if let existing = surfaces[key], existing.isRunning { return existing }
        let surface = SwiftTermSurface()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment.removeValue(forKey: "CLAUDECODE")
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        surface.start(ProjectShell.command(root: root, host: host, shell: shell, environment: environment))
        surfaces[key] = surface
        return surface
    }

    /// Whether a shell is running for the project, for the tests' report.
    func isRunning(root: String, host: String?) -> Bool {
        surfaces[(host ?? "") + "\u{0}" + root]?.isRunning ?? false
    }

    func endAll() {
        surfaces.values.forEach { $0.end(waiting: false) }
        surfaces = [:]
    }
}

/// The shell's view, for SwiftUI.
struct HubShellView: NSViewRepresentable {
    let shells: HubShells
    let root: String
    let host: String?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let view = shells.surface(root: root, host: host).view
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

/// The last column: the open file, or the project's shell.
struct HubLastColumnView: View {
    @ObservedObject var files: HubFilesModel
    let shells: HubShells

    var body: some View {
        Group {
            if files.lastColumn == .terminal, let source = files.source {
                VStack(spacing: 0) {
                    HStack {
                        Text("Shell in \((source.root as NSString).lastPathComponent)\(source.isRemote ? " · \(source.host ?? "")" : "")")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text("Not the session: what you type here stays in this shell").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    HubShellView(shells: shells, root: source.root, host: source.host)
                }
                .accessibilityIdentifier("hub.shell")
            } else {
                HubViewerView(files: files)
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }
}
