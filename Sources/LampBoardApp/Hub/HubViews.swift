import AppKit
import LampBoardCore
import SwiftUI

/// LampMaster as a row above the sessions (D151): its own lamp — working while
/// a round runs, green while cards wait, resting otherwise — its count, the time
/// of its last round and the line the panel's strip says.
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
                Circle().fill(StatusPalette.color(for: status)).frame(width: 11, height: 11).padding(.top, 2)
                Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StatusPalette.lampMasterTint).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("LampMaster").font(.system(size: 12, weight: .medium, design: .rounded))
                        if !service.snapshot.open.isEmpty {
                            Text("\(service.snapshot.open.count)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                                .foregroundStyle(StatusPalette.lampMasterTint)
                        }
                        Spacer(minLength: 4)
                        if let last = service.snapshot.lastRound {
                            Text(RelativeTime.label(for: last.at, now: Date())).font(.system(size: 12, design: .rounded))
                                .monospacedDigit().foregroundStyle(StatusPalette.timeColor)
                        }
                    }
                    Text(LampMasterLine.text(open: service.snapshot.open.count, last: service.snapshot.lastRound,
                                             running: service.snapshot.running,
                                             time: { $0.formatted(date: .omitted, time: .shortened) }))
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(StatusPalette.timeColor)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hub.lampmaster")
        .accessibilityLabel("LampMaster, \(service.snapshot.open.count) cards")
    }
}

/// The first column: LampMaster's row, then the panel's own view (D150).
struct HubSidebarView: View {
    @ObservedObject var model: HubModel
    let panel: AnyView

    var body: some View {
        VStack(spacing: 0) {
            if let service = model.deps.lampMaster, service.snapshot.enabled {
                HubLampMasterRow(service: service, selected: model.selected == HubModel.lampMasterId) {
                    model.selected = HubModel.lampMasterId
                }
                .padding(.horizontal, 4).padding(.top, 6)
                Divider().padding(.top, 4)
            }
            ScrollView(.vertical) {
                panel.environment(\.columnFillsWidth, true).environment(\.hubSelection, model.selected)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 220, maxHeight: .infinity, alignment: .top)
        // The panel's dark material, full height: the rows are drawn for it (D150).
        .background(PanelBackground().overlay(StatusPalette.panelScrim).ignoresSafeArea())
    }
}

/// The second column: the open conversation, its waiting card, and how Send goes.
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
            Divider()
            PlanciaPendingCard(queue: model.deps.queue, sessionId: session.id).padding(.top, 6)
            if let chat = model.chat {
                LiveChatView(model: chat, send: { model.send($0) }, showTerminal: { model.deps.openRealWindow(session.id) })
                if let live = model.live, !live.text.isEmpty { liveBubble(live.text) }
            } else {
                empty("No transcript to read for this session yet.")
            }
            Divider()
            footer
        }
    }

    private func header(_ session: SessionState) -> some View {
        HStack(spacing: 8) {
            Circle().fill(StatusPalette.color(for: session.status)).frame(width: 11, height: 11)
            Text(session.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(meta(session)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if session.status == .working || session.status == .waiting {
                Button("Stop") { model.stop() }
                    .help("Stops the turn. Commands it started in the background keep running.")
                    .accessibilityIdentifier("hub.stop")
            }
            Button("Open the real window") { model.deps.openRealWindow(session.id) }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("hub.openReal")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    /// The reply as it arrives: provisional, in grey, until the transcript has it.
    private func liveBubble(_ text: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Writing…").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(text).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("live-end")
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
            .frame(maxHeight: 180)
            .onChange(of: text) { _, _ in proxy.scrollTo("live-end", anchor: .bottom) }
        }
        .accessibilityIdentifier("hub.live")
    }

    private func meta(_ session: SessionState) -> String {
        var parts: [String] = []
        if let host = session.workspace.host { parts.append(host) }
        parts.append(session.status.label)
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("Send", selection: $model.mode) {
                Text("Interrupt").tag(HubWrite.Mode.interrupt)
                Text("Queue").tag(HubWrite.Mode.queue)
                Text("Steer").tag(HubWrite.Mode.steer)
            }
            .pickerStyle(.segmented).fixedSize()
            .help("Interrupt stops the turn and sends; Queue sends when the session is free; Steer reaches the running turn")
            .accessibilityIdentifier("hub.mode")
            Text(routeLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var routeLine: String {
        switch model.route {
        case .mod: return "Sent through the session's LampBoard helper, as your words"
        case .box: return "Sent through the session's message box"
        case .paste: return "Typed into the session's terminal"
        case .none: return "Read only from here: open the session's window to write"
        }
    }

    private func empty(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center); Spacer() }
            .frame(maxWidth: .infinity)
            .padding()
    }
}
