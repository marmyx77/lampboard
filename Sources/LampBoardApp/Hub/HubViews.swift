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

    var body: some View {
        Group {
            if model.selected == HubModel.lampMasterId {
                lampMaster
            } else if let session = model.session {
                conversation(session)
            } else {
                empty("Choose a session on the left to open its conversation.")
            }
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(HubPalette.panel)
        .foregroundStyle(HubPalette.ink)
    }

    @ViewBuilder private var lampMaster: some View {
        if let service = model.deps.lampMaster, let actions = model.deps.lampMasterActions {
            LampMasterPlanciaContent(service: service, actions: actions)
        } else {
            empty("LampMaster is off. Turn it on in Settings › LampMaster.")
        }
    }

    private func conversation(_ session: SessionState) -> some View {
        VStack(spacing: 0) {
            header(session)
            line
            PlanciaPendingCard(queue: model.deps.queue, sessionId: session.id).padding(.horizontal, 14).padding(.top, 8)
            if let chat = model.chat {
                LiveChatView(model: chat, send: { _ in false }, showTerminal: { model.deps.openRealWindow(session.id) }, composes: false)
                HubLiveBubble(tail: model.liveTail)
            } else {
                empty("No transcript to read for this session yet.")
            }
            HubPresenceLine(composer: model.composer, model: model)
            VStack(alignment: .leading, spacing: 8) {
                HubComposerView(composer: model.composer, submit: { model.submit() }, canWrite: model.route != .none)
                HubBarView(bar: model.bar, composer: model.composer, model: model, session: session)
                buttons(session)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .top) { line }
        }
    }

    private var line: some View { Rectangle().fill(HubPalette.line).frame(height: 1) }

    private func header(_ session: SessionState) -> some View {
        HStack(spacing: 10) {
            HubLamp(color: StatusPalette.color(for: session.status))
            Text(session.displayName).font(.system(size: 15, weight: .bold)).lineLimit(1)
            Text(meta(session)).font(.system(size: 12)).foregroundStyle(HubPalette.muted).lineLimit(1)
            Spacer(minLength: 8)
            Button("Open the real window ⌘↩") { model.deps.openRealWindow(session.id) }
                .buttonStyle(HubButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("hub.openReal")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Where it runs, how it was opened, its mode and its model's letter.
    private func meta(_ session: SessionState) -> String {
        var parts = [session.workspace.host ?? "This Mac"]
        switch session.entrypoint {
        case "claude-vscode": parts.append("VS Code")
        case "claude-desktop": parts.append("Desktop")
        default: parts.append(session.origin == .background ? "background" : "Terminal")
        }
        if let mode = model.bar.mode { parts.append("mode \(mode.title.lowercased())") }
        if let letter = session.context?.modelInitial, !letter.isEmpty { parts.append(letter) }
        return parts.joined(separator: " · ")
    }

    /// Send in the chosen mode, its menu for the other two (Marco's Hermes
    /// choice), Message now, Stop, and the way it goes.
    private func buttons(_ session: SessionState) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(HubWrite.Mode.allCases, id: \.self) { mode in
                    Button(Self.title(mode)) { model.mode = mode; model.submit() }
                }
            } label: {
                Text(Self.title(model.mode))
            } primaryAction: {
                model.submit()
            }
            .menuStyle(.button).menuIndicator(.visible).fixedSize()
            .buttonStyle(HubButtonStyle(kind: .primary))
            .disabled(model.route == .none)
            .accessibilityIdentifier("hub.send")
            if model.mode != .steer {
                Button("Message now") { let kept = model.mode; model.mode = .steer; model.submit(); model.mode = kept }
                    .buttonStyle(HubButtonStyle())
                    .disabled(model.route == .none)
                    .help("Into the running turn, through the session's message box")
            }
            Button("Stop") { model.stop() }
                .buttonStyle(HubButtonStyle(kind: .danger))
                .disabled(!(session.status == .working || session.status == .waiting))
                .help("Stops the turn. Commands it started in the background keep running.")
                .accessibilityIdentifier("hub.stop")
            Spacer(minLength: 8)
            Text(model.notice ?? routeLine).font(.system(size: 11))
                .foregroundStyle(model.notice == nil ? HubPalette.muted : HubPalette.amber).lineLimit(2)
        }
    }

    static func title(_ mode: HubWrite.Mode) -> String {
        switch mode {
        case .queue: return "Queue"
        case .interrupt: return "Interrupt and send"
        case .steer: return "Message now"
        }
    }

    private var routeLine: String {
        switch model.route {
        case .mod: return "\(Self.title(model.verdict.mode)) → the session's helper, as your words"
        case .box: return "Into the session's message box"
        case .paste: return "Typed into the session's terminal"
        case .none: return "Read only from here: open the session's window to write"
        }
    }

    private func empty(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(HubPalette.muted).multilineTextAlignment(.center); Spacer() }
            .frame(maxWidth: .infinity)
            .padding()
    }
}

/// The line above the composer (the proposal's `.presence`): what the
/// session's own box holds, amber when it matters for Send.
struct HubPresenceLine: View {
    @ObservedObject var composer: HubComposer
    @ObservedObject var model: HubModel

    var body: some View {
        let warn = composer.band != nil || composer.boxHasDraft
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warn ? HubPalette.ink : HubPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(warn ? HubPalette.amberSoft : HubPalette.soft)
            .overlay(alignment: .top) { Rectangle().fill(HubPalette.line).frame(height: 1) }
            .accessibilityIdentifier("hub.presence")
    }

    private var text: String {
        if let band = composer.band { return band }
        guard let id = model.selected else { return "" }
        if composer.boxHasDraft { return "Something is typed in the session's own box: Send asks first, and what is typed there stays." }
        if model.commandable.contains(id) { return "Nothing typed in the session's own box." }
        return "Without LampBoard's helper in this session the Hub cannot see its box."
    }
}

/// The reply as it is written, apart from the conversation so that a piece
/// redraws this and nothing else: a fixed height, the last lines at the bottom,
/// so nothing around it moves.
struct HubLiveBubble: View {
    @ObservedObject var tail: HubLiveTail

    var body: some View {
        if !tail.text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Writing…").font(.system(size: 10, weight: .semibold)).foregroundStyle(HubPalette.muted)
                Text(tail.text + " ▍").font(.system(size: 13).italic()).foregroundStyle(HubPalette.muted)
                    .lineLimit(HubLiveTail.lines)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(height: 170)
            .clipped()
            .accessibilityIdentifier("hub.live")
        }
    }
}
