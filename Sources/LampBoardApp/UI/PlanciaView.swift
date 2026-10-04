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

    enum Tab: String, CaseIterable { case thread = "Thread", activity = "Activity", cost = "Cost" }
    @State private var tab: Tab = .thread

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .accessibilityLabel("Plancia tab")
                Spacer()
                Button { model.pinned.toggle() } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.pinned ? Color.primary : StatusPalette.timeColor)
                .tooltip(model.pinned ? "Pinned open. Click to let it close by itself." : "Keep the Plancia open")
                .accessibilityLabel(model.pinned ? "Unpin the Plancia" : "Pin the Plancia open")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StatusPalette.timeColor)
                .tooltip("Back to the panel (Esc)")
                .accessibilityLabel("Close the Plancia")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            if let id = model.sessionId {
                switch tab {
                case .thread:
                    if let thread = model.thread {
                        ChatView(session: thread) { openInEditor(id) }.id(id)
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
            PlanciaNote(text: "Nothing yet. Tools appear here as the session runs them, with the companion mod installed.")
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
                Text(session?.costUSD == nil ? "The companion mod reports the cost; without it there is no figure."
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
