import AppKit
import ClarcChatKit
import LampBoardCore
import SwiftUI

/// LampMaster as the first row (D151), drawn as the proposal draws it: its lamp
/// (working while a round runs, green while cards wait), the spark, its count,
/// the time of its last round, and the line the panel's strip says.
struct HubLampMasterRow: View {
    @ObservedObject var service: LampMasterService
    let selected: Bool
    let open: () -> Void

    private var status: SessionStatus {
        if service.snapshot.running { return .working }
        return service.snapshot.open.isEmpty ? .idle : .ready
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 7) {
                HubLamp(color: StatusPalette.color(for: status)).padding(.top, 3)
                Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StatusPalette.lampMasterTint).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("LampMaster").font(.system(size: 13, weight: .semibold)).foregroundStyle(HubPalette.ink)
                        if !service.snapshot.open.isEmpty {
                            Text("\(service.snapshot.open.count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .foregroundStyle(StatusPalette.lampMasterTint)
                        }
                        Spacer(minLength: 4)
                        if let last = service.snapshot.lastRound {
                            Text(RelativeTime.label(for: last.at, now: Date())).font(.system(size: 12))
                                .monospacedDigit().foregroundStyle(HubPalette.muted)
                        }
                    }
                    Text(LampMasterLine.text(open: service.snapshot.open.count, last: service.snapshot.lastRound,
                                             running: service.snapshot.running,
                                             time: { $0.formatted(date: .omitted, time: .shortened) }))
                        .font(.system(size: 11)).foregroundStyle(HubPalette.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? HubPalette.accentSoft : .clear))
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(HubPalette.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hub.lampmaster")
        .accessibilityLabel("LampMaster, \(service.snapshot.open.count) cards")
    }
}

/// The first column: LampMaster's row, then the panel's own rows (D150).
struct HubSidebarView: View {
    @ObservedObject var model: HubModel
    let panel: AnyView

    var body: some View {
        VStack(spacing: 0) {
            if let service = model.deps.lampMaster, service.snapshot.enabled {
                HubLampMasterRow(service: service, selected: model.selected == HubModel.lampMasterId) {
                    model.selected = HubModel.lampMasterId
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
                Rectangle().fill(HubPalette.line).frame(height: 1)
            }
            ScrollView(.vertical) {
                panel.environment(\.columnFillsWidth, true).environment(\.hubSelection, model.selected)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
            }
        }
        .frame(minWidth: 220, maxHeight: .infinity, alignment: .top)
        .background(HubPalette.soft.ignoresSafeArea())
    }
}

/// The second column: the open conversation, its waiting card, the line that
/// says what the session's own box holds, and the composer with its bar.
struct HubConversationView: View {
    @ObservedObject var model: HubModel
    /// The rows' state: the lamp and the time follow the session.
    @ObservedObject var store: StateStore

    var body: some View {
        VStack(spacing: 0) {
            if model.guideShown { HubGuideBand(dismiss: model.dismissGuide) }
            content
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(HubPalette.panel)
        .foregroundStyle(HubPalette.ink)
    }

    @ViewBuilder private var content: some View {
        switch model.centre {
        case .lampMaster:
            lampMaster
        case .terminal(let target):
            if let session = model.session {
                header(session) { terminalButtons(target) }
                HubTerminalHost(model: model, target: target)
                    .accessibilityIdentifier("hub.terminal.session")
            }
        case .inWindow:
            if let session = model.session {
                header(session) { EmptyView() }
                VStack(spacing: 12) {
                    Spacer()
                    Text("This session is open in a window of its own.").foregroundStyle(HubPalette.muted)
                    Button("Bring it here") { model.bringBack() }.buttonStyle(HubButtonStyle(kind: .primary))
                        .accessibilityIdentifier("hub.bringBack")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        case .reading:
            if let session = model.session { reading(session) }
        case .none:
            empty("Choose a session on the left: it opens here, in its own terminal.")
        }
    }

    @ViewBuilder private var lampMaster: some View {
        if let service = model.deps.lampMaster, let actions = model.deps.lampMasterActions {
            LampMasterPlanciaContent(service: service, actions: actions)
        } else {
            empty("LampMaster is off. Turn it on in Settings › LampMaster.")
        }
    }

    /// A session LampBoard has no terminal into: its transcript, read, and the
    /// ways to reach it.
    private func reading(_ session: SessionState) -> some View {
        VStack(spacing: 0) {
            header(session) {
                if let move = model.deps.move(session.id) {
                    Button("Move to LampBoard…", action: move).buttonStyle(HubButtonStyle(kind: .primary)).fixedSize()
                        .help("Its VS Code tab stops, and the conversation goes on here, in its own terminal.")
                        .accessibilityIdentifier("hub.move")
                }
                Button(Self.openTitle(session)) { model.deps.openRealWindow(session.id) }
                    .buttonStyle(HubButtonStyle()).fixedSize()
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("hub.openReal")
            }
            Text(Self.readingLine(session))
                .font(.system(size: 11)).foregroundStyle(HubPalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(HubPalette.soft)
                .accessibilityIdentifier("hub.readingLine")
            line
            if let reader = model.reader {
                LiveChatView(model: reader, send: { _ in false }, showTerminal: { model.deps.openRealWindow(session.id) },
                             composes: false, cite: { _ in })
                    .id(ObjectIdentifier(reader))
            } else {
                empty("No transcript to read for this session yet.")
            }
        }
    }

    private func terminalButtons(_ target: LiveTarget) -> some View {
        HStack(spacing: 8) {
            if model.hasLeft(target) {
                Button("Open again") { model.reattach(target) }.buttonStyle(HubButtonStyle(kind: .primary)).fixedSize()
                    .accessibilityIdentifier("hub.reattach")
            }
            Button {
                model.popOut()
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .buttonStyle(HubButtonStyle()).fixedSize()
            .help("In a window of its own; the same terminal, the session goes on")
            .accessibilityIdentifier("hub.popOut")
        }
    }

    private var line: some View { Rectangle().fill(HubPalette.line).frame(height: 1) }

    private func header<Trailing: View>(_ session: SessionState, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HubLamp(color: StatusPalette.color(for: session.status))
                Text(session.displayName).font(.system(size: 15, weight: .bold)).lineLimit(1).layoutPriority(2)
                Text(meta(session)).font(.system(size: 12)).foregroundStyle(HubPalette.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            line
        }
    }

    /// Where it runs, how it was opened, and its model's letter.
    private func meta(_ session: SessionState) -> String {
        var parts = [session.workspace.name, session.workspace.host ?? "This Mac"]
        parts.append(Self.surface(session))
        if let letter = session.context?.modelInitial, !letter.isEmpty { parts.append(letter) }
        return parts.joined(separator: " · ")
    }

    static func surface(_ session: SessionState) -> String {
        switch session.entrypoint {
        case "claude-vscode": return "VS Code"
        case "claude-desktop": return "Claude app"
        default: return session.origin == .background ? "background" : "terminal"
        }
    }

    static func openTitle(_ session: SessionState) -> String {
        switch session.entrypoint {
        case "claude-vscode": return "Show in VS Code ⌘↩"
        case "claude-desktop": return "Show in the Claude app ⌘↩"
        default: return "Show its window ⌘↩"
        }
    }

    static func readingLine(_ session: SessionState) -> String {
        switch session.entrypoint {
        case "claude-vscode":
            return "This session runs in VS Code's panel: LampBoard reads it. Move it here to write to it in its own terminal."
        case "claude-desktop":
            return "This session runs in the Claude app: LampBoard reads it. Write to it there."
        default:
            return "LampBoard has no terminal into this session (not in tmux, not in the background): it reads it."
        }
    }

    private func empty(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(HubPalette.muted).multilineTextAlignment(.center); Spacer() }
            .frame(maxWidth: .infinity)
            .padding()
    }
}

/// The session's terminal in the centre: the live view's frame, seated here,
/// and the keys given to it whenever the session changes.
struct HubTerminalHost: NSViewRepresentable {
    let model: HubModel
    let target: LiveTarget

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        seat(in: container, context: context)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        seat(in: container, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var seated: LiveTarget? }

    private func seat(in container: NSView, context: Context) {
        // Once a target: `hosted` attaches, or takes a terminal back from its
        // window, so it is asked only when the session changes. A terminal that
        // left for a window of its own is not called back by a redraw.
        guard context.coordinator.seated != target else { return }
        guard let frame = model.terminalView(for: target) else { return }
        context.coordinator.seated = target
        container.subviews.forEach { $0.removeFromSuperview() }
        frame.removeFromSuperview()
        frame.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            frame.topAnchor.constraint(equalTo: container.topAnchor),
            frame.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let target = self.target
        DispatchQueue.main.async { [weak model] in
            guard let terminal = model?.terminal(for: target) else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

/// The first time the Hub opens: where things are, in four lines, until read.
struct HubGuideBand: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb").foregroundStyle(HubPalette.accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("This is the Hub").font(.system(size: 13, weight: .semibold))
                Group {
                    Text("Your sessions on the left, the panel's rows in your order. The one you choose opens here, in its own terminal: Claude Code itself, with / for commands, Shift-Tab for the mode and Esc to stop.")
                    Text("A session in VS Code's panel is read here; Move to LampBoard brings it into a terminal of its own.")
                    Text("Files, the open file and a shell in the project come and go with the icons at the top right.")
                }
                .font(.system(size: 12)).foregroundStyle(HubPalette.muted)
            }
            Spacer(minLength: 8)
            Button("Got it", action: dismiss).buttonStyle(HubButtonStyle(kind: .primary)).accessibilityIdentifier("hub.guide.done")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(HubPalette.accentSoft)
        .overlay(alignment: .bottom) { Rectangle().fill(HubPalette.line).frame(height: 1) }
        .accessibilityIdentifier("hub.guide")
    }
}
