import AppKit
import LampBoardCore
import SwiftUI

/// What the command bar knows of the open session (D157): its commands, the
/// footer's mode, whether Remote Control is on, and the model and effort the
/// person chose for it. Apart from `HubModel`, so the bar redraws alone.
@MainActor
final class HubBarState: ObservableObject {
    @Published private(set) var commands: [ModReport.Command] = []
    @Published private(set) var mode: HubBar.Mode?
    @Published private(set) var remote = false
    @Published private(set) var model: String?
    @Published private(set) var effort: String?
    /// A model change waiting for its second click: the cache is warm.
    @Published private(set) var warning: String?
    /// A mode being reached by Shift+Tab.
    @Published private(set) var reaching: HubBar.Mode?

    private var chosen: [String: (model: String?, effort: String?)] = [:]
    private var session: String?

    var names: Set<String> { Set(commands.map(\.name)) }

    func show(session id: String?) {
        guard id != session else { return }
        session = id
        commands = []
        mode = nil
        remote = false
        warning = nil
        reaching = nil
        model = id.flatMap { chosen[$0]?.model }
        effort = id.flatMap { chosen[$0]?.effort }
    }

    func heard(commands list: [ModReport.Command]) { commands = list }
    func heard(mode value: HubBar.Mode?) {
        if mode != value { mode = value }
        if reaching != nil, reaching == value { reaching = nil }
    }
    func heard(surfaces list: [String]) { remote = list.contains("mobile") }

    func warn(_ text: String?) { warning = text }
    func reach(_ target: HubBar.Mode?) { reaching = target }

    func chose(model value: String?, for id: String) {
        model = value
        chosen[id] = (value, chosen[id]?.effort)
        warning = nil
    }

    func chose(effort value: String?, for id: String) {
        effort = value
        chosen[id] = (chosen[id]?.model, value)
    }
}

/// The bar under the box (the proposal's `.cbar`): `+` and `/`, the context
/// and the time, Remote Control, the agents, then the model and the mode, each
/// a pill with its own little window. Each acts through `HubModel`.
struct HubBarView: View {
    @ObservedObject var bar: HubBarState
    @ObservedObject var composer: HubComposer
    let model: HubModel
    let session: SessionState

    @State private var open: Pop?
    @State private var filter = ""

    enum Pop: String, Identifiable { case attach, commands, model, mode; var id: String { rawValue } }

    struct Choice: Identifiable { let id: String; let title: String; let detail: String; let current: Bool; let act: () -> Void }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let warning = bar.warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(HubPalette.amber).accessibilityIdentifier("hub.bar.warning")
            }
            if !typed.isEmpty { typedCommands }
            HubFlow(spacing: 6).callAsFunction {
                Button { open = .attach } label: { Image(systemName: "plus") }
                    .buttonStyle(HubIconStyle()).help("Attach or cite")
                    .popover(item: binding(.attach), arrowEdge: .top) { _ in pop(.attach) }
                    .accessibilityIdentifier("hub.bar.attach")
                Button { filter = ""; open = .commands } label: { Image(systemName: "slash.circle") }
                    .buttonStyle(HubIconStyle()).help("The session's commands").disabled(bar.commands.isEmpty)
                    .popover(item: binding(.commands), arrowEdge: .top) { _ in pop(.commands) }
                ContextRing(reading: session.context).scaleEffect(0.9)
                if let fraction = session.context?.fraction {
                    Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(HubPalette.muted)
                }
                Text(RelativeTime.label(for: session.statusSince, now: Date())).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(HubPalette.muted)
                Button(bar.remote ? "Remote Control · phone" : "Remote Control") { model.toggleRemoteControl() }
                    .buttonStyle(HubPillStyle(on: bar.remote))
                    .disabled(!bar.names.contains("remote-control"))
                    .help("Claude Code's Remote Control, to follow this session from the phone")
                    .accessibilityIdentifier("hub.bar.remote")
                Text(session.activeSubagents == 1 ? "1 agent" : "\(session.activeSubagents) agents")
                    .font(.system(size: 11)).foregroundStyle(HubPalette.muted)
                Button(modelTitle) { open = .model }
                    .buttonStyle(HubPillStyle())
                    .popover(item: binding(.model), arrowEdge: .top) { _ in pop(.model) }
                    .help("For this session only, from its next request")
                    .accessibilityIdentifier("hub.bar.model")
                Button(modeTitle) { open = .mode }
                    .buttonStyle(HubPillStyle())
                    .popover(item: binding(.mode), arrowEdge: .top) { _ in pop(.mode) }
                    .accessibilityIdentifier("hub.bar.mode")
            }
        }
    }

    private func binding(_ which: Pop) -> Binding<Pop?> {
        Binding(get: { open == which ? which : nil }, set: { open = $0 })
    }

    @ViewBuilder private func pop(_ which: Pop) -> some View {
        switch which {
        case .attach:
            list("Attach", [
                Choice(id: "upload", title: "Upload from this Mac…", detail: "copied into the project's .lampboard/allegati, cited as @path",
                       current: false) { open = nil; model.attach() },
                Choice(id: "cite", title: "Cite a project file", detail: "opens the files: drag one into the text",
                       current: false) { open = nil; model.showFiles?() },
            ], note: "A path, not the bytes: the session reads the file with its own Read.")
        case .commands:
            list("Commands", bar.commands.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.map { command in
                Choice(id: command.name, title: "/" + command.name, detail: command.description, current: false) {
                    open = nil; composer.text = "/\(command.name) "
                }
            }, filter: $filter, note: "The session's own list; a command runs when the session is free.")
        case .model:
            list("Model and effort", [Choice(id: "default", title: "Session's own", detail: "as Claude Code chose it", current: bar.model == nil) {
                open = nil; model.choose(model: nil)
            }] + HubBar.models.map { item in
                Choice(id: item.id, title: item.title, detail: item.id, current: bar.model == item.id) { open = nil; model.choose(model: item.id) }
            } + HubBar.efforts.map { effort in
                Choice(id: "effort-" + effort, title: "Effort " + effort, detail: "", current: bar.effort == effort) {
                    open = nil; model.choose(effort: effort)
                }
            }, note: "For this session only, from its next request. Over a warm cache the Hub asks twice.")
        case .mode:
            list("Permission mode", HubBar.cycle.map { mode in
                Choice(id: mode.rawValue, title: mode.title, detail: model.canReach(mode) ? "" : "not from here now",
                       current: bar.mode == mode) { open = nil; model.choose(mode: mode) }
            }, note: "Plan through the session's /plan; the others with Shift+Tab where LampBoard shows its terminal, never over a dialog.")
        }
    }

    private func list(_ title: String, _ items: [Choice], filter: Binding<String>? = nil, note: String) -> some View {
        HubPopList(title: title, items: items, filter: filter, note: note,
                   label: { ($0.title, $0.detail, $0.current) }, pick: { $0.act() })
            .environment(\.colorScheme, .dark)
    }

    /// The commands matching what is typed after `/`, while it is one word.
    private var typed: [ModReport.Command] {
        let text = composer.text
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let word = text.dropFirst().lowercased()
        return Array(bar.commands.filter { word.isEmpty || $0.name.lowercased().hasPrefix(word) }.prefix(8))
    }

    private var typedCommands: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(typed, id: \.name) { command in
                Button { composer.text = "/\(command.name) " } label: {
                    HStack(spacing: 8) {
                        Text("/\(command.name)").font(HubPalette.mono).foregroundStyle(HubPalette.ink)
                        Text(command.description).font(.system(size: 11)).foregroundStyle(HubPalette.muted).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(HubPalette.soft))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(HubPalette.line))
        .accessibilityIdentifier("hub.bar.commands")
    }

    private var modelTitle: String {
        let name = bar.model.flatMap { id in HubBar.models.first { $0.id == id }?.title }
            ?? session.context.map { reading in
                HubBar.models.first(where: { reading.model.hasPrefix($0.id) })?.title ?? reading.model
            } ?? "Model"
        return "\(name) · \(bar.effort ?? "default")"
    }

    private var modeTitle: String {
        if let reaching = bar.reaching { return "⚡ → \(reaching.title)…" }
        return "⚡ " + (bar.mode?.title ?? "Mode")
    }
}
