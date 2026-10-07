import LampBoardCore
import SwiftUI

/// The Plancia (UX §5, D79): the session in focus, open beside the list toward
/// the middle of the screen, in three tabs — its conversation (the chat
/// window's own view), what it has been doing, and what it costs.
struct PlanciaView: View {
    @ObservedObject var model: PlanciaModel
    @ObservedObject var store: StateStore
    let activity: ActivityRecorder?
    let openInEditor: (String) -> Void
    let close: () -> Void
    var lampMaster: LampMasterService? = nil
    var lampMasterActions: LampMasterActions? = nil
    /// What the header's buttons do (UX §5): go to its window, hand it over, mute it.
    var actions: PlanciaActions? = nil
    /// What waits, for the card of this session pinned at the top (UX §5).
    var queue: WaitingQueueModel? = nil

    enum Tab: String, CaseIterable { case thread = "Thread", activity = "Activity", cost = "Cost" }
    @State private var tab: Tab = .thread

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.showsLampMaster {
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(StatusPalette.lampMasterTint)
                    Text("LampMaster").font(.system(size: 12, weight: .semibold, design: .rounded))
                } else {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                    .accessibilityLabel("Session view tab")
                }
                Spacer()
                Button { model.pinned.toggle() } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.pinned ? Color.primary : StatusPalette.timeColor)
                .tooltip(model.pinned ? "Pinned open. Click to let it close by itself." : "Keep the Session view open")
                .accessibilityLabel(model.pinned ? "Unpin the Session view" : "Pin the Session view open")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StatusPalette.timeColor)
                .tooltip("Back to the panel (Esc)")
                .accessibilityLabel("Close the Session view")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            if model.showsLampMaster, let lampMaster, let lampMasterActions {
                LampMasterPlanciaContent(service: lampMaster, actions: lampMasterActions, sheet: model.lampMasterSheet)
            } else if let id = model.sessionId {
                if let session = store.state.session(named: id) {
                    PlanciaHeaderView(session: session, actions: actions)
                    if let queue { PlanciaPendingCard(queue: queue, sessionId: id) }
                    Divider()
                }
                switch tab {
                case .thread:
                    if let thread = model.thread {
                        ChatView(session: thread, openInEditor: { openInEditor(id) }, showsHeader: false).id(id)
                    }
                case .activity:
                    PlanciaActivity(log: activityLog(id))
                case .cost:
                    PlanciaCost(session: store.state.session(named: id), log: activityLog(id))
                }
            } else {
                Spacer()
            }
        }
        .frame(width: PanelDepth.plancia.width - PanelDepth.panel.width - 1)
    }

    private func activityLog(_ id: String) -> SessionActivity {
        activity?.logs[id] ?? SessionActivity()
    }
}

/// What the session has been doing, newest first: each tool and how long it
/// ran, each turn and what it cost. From the companion mod and the hooks.
struct PlanciaActivity: View {
    let log: SessionActivity

    var body: some View {
        if log.entries.isEmpty {
            PlanciaNote(text: "Nothing yet. Tools appear here as the session runs them, with the helper installed.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(log.entries.reversed().enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(StatusPalette.timeColor)
                                .frame(width: 44, alignment: .leading)
                            Text(title(entry)).font(.system(size: 11, design: .rounded)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(trailing(entry)).font(.system(size: 10)).monospacedDigit().foregroundStyle(StatusPalette.timeColor)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func title(_ entry: SessionActivity.Entry) -> String {
        switch entry.kind {
        case .tool(let name, let detail): return detail.map { "\(name) \($0)" } ?? name
        case .turn: return "turn ended"
        }
    }

    private func trailing(_ entry: SessionActivity.Entry) -> String {
        switch entry.kind {
        case .tool: return entry.seconds.map { CompactDuration.label(seconds: $0) } ?? "running"
        case .turn: return entry.costUSD.map { RowSummary.spelled(dollars: $0) } ?? ""
        }
    }
}

/// What the session costs: its context, the total the mod reported, and what
/// each recent turn cost.
struct PlanciaCost: View {
    let session: SessionState?
    let log: SessionActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let context = session?.context {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context").font(.system(size: 10, weight: .semibold)).foregroundStyle(StatusPalette.timeColor)
                    Text(context.label).font(.system(size: 12, design: .rounded))
                    ProgressView(value: min(max(context.fraction ?? 0, 0), 1)).tint(StatusPalette.color(for: .working))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("This session").font(.system(size: 10, weight: .semibold)).foregroundStyle(StatusPalette.timeColor)
                Text(session?.costUSD.map { RowSummary.spelled(dollars: $0) } ?? "—")
                    .font(.system(size: 12, design: .rounded))
                Text(session?.costUSD == nil ? "The helper reports the cost; without it there is no figure."
                                             : "Counted by Claude Code at list price.")
                    .font(.system(size: 10)).foregroundStyle(StatusPalette.timeColor)
            }
            let turns = log.entries.filter { $0.kind == .turn }.compactMap(\.costUSD)
            if !turns.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent turns").font(.system(size: 10, weight: .semibold)).foregroundStyle(StatusPalette.timeColor)
                    Text(turns.suffix(8).map { RowSummary.spelled(dollars: $0) }.joined(separator: " · "))
                        .font(.system(size: 11, design: .rounded)).monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlanciaNote: View {
    let text: String

    var body: some View {
        VStack {
            Text(text).font(.system(size: 11)).foregroundStyle(StatusPalette.timeColor).multilineTextAlignment(.center)
                .padding(24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// What the Plancia's header can ask of the panel (UX §5).
struct PlanciaActions {
    /// Raises the session's own window, as a click on its row does.
    let go: (String) -> Void
    /// Opens the bar on `/handoff @this @`, for the person to name who takes over (D91).
    let handOver: (String) -> Void
    /// Mutes or unmutes the session's project, as the row's menu does.
    let toggleMuted: (String) -> Void
    let isMuted: (String) -> Bool
    /// Puts the session in the foreground, or takes it out (G1).
    var toggleFocus: (String) -> Void = { _ in }
    var isFocused: (String) -> Bool = { _ in false }
}

/// The session in focus, above every tab (UX §5): its lamp, its name, the line of
/// facts — machine, surface and agent, model, context, cost — and what can be done
/// to it from here: Go, Hand over, Mute, Focus (G1). Resume waits for closed
/// conversations in the Plancia.
struct PlanciaHeaderView: View {
    let session: SessionState
    let actions: PlanciaActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(StatusPalette.color(for: session.status))
                    .frame(width: 9, height: 9)
                    .opacity(StatusPalette.opacity(for: session.status))
                VStack(alignment: .leading, spacing: 1) {
                    Text(RowActivity.flat(session.displayName))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(PlanciaHeader.facts(session))
                        .font(.system(size: 10))
                        .foregroundStyle(StatusPalette.timeColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            if let actions {
                HStack(spacing: 6) {
                    button("Go", "arrow.up.forward.app", "Raise its window") { actions.go(session.id) }
                    button("Hand over", "arrow.right.doc.on.clipboard", "Write a handoff for another session (/handoff)") {
                        actions.handOver(session.id)
                    }
                    let muted = actions.isMuted(session.id)
                    button(muted ? "Unmute" : "Mute", muted ? "bell" : "bell.slash",
                           muted ? "Notify again for this project" : "No notifications for this project") {
                        actions.toggleMuted(session.id)
                    }
                    let focused = actions.isFocused(session.id)
                    button(focused ? "Unfocus" : "Focus", focused ? "pin.slash" : "pin",
                           focused ? "Let the other sessions notify again" : "The other sessions' notifications wait until you take it off") {
                        actions.toggleFocus(session.id)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func button(_ title: String, _ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tooltip(tip)
    }
}

/// The session's own waiting card, pinned under its header (UX
/// §5): the same card, the same armed buttons, answered from here as from the
/// queue. Nothing when the session waits for nothing.
struct PlanciaPendingCard: View {
    @ObservedObject var queue: WaitingQueueModel
    let sessionId: String

    var body: some View {
        if let card = queue.cards.first(where: { $0.sessionIds.contains(sessionId) }) {
            WaitingCardView(card: card, selected: false, armed: queue.isArmed(card), resolved: false,
                            onAnswer: { queue.answer(card, $0) }, onChoose: { queue.choose(card, $0) })
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }
}
