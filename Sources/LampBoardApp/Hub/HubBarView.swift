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
    func heard(mode label: String) {
        mode = HubBar.mode(footer: label)
        if reaching == mode { reaching = nil }
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

/// The bar above the box: `+` to attach, `/` commands, model and effort, the
/// mode, Remote Control. Each control acts through `HubModel`.
struct HubBarView: View {
    @ObservedObject var bar: HubBarState
    @ObservedObject var composer: HubComposer
    let model: HubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let warning = bar.warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).accessibilityIdentifier("hub.bar.warning")
            }
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(matches, id: \.name) { command in
                        Button { composer.text = "/\(command.name) " } label: {
                            HStack(spacing: 8) {
                                Text("/\(command.name)").font(.system(size: 12, design: .monospaced))
                                Text(command.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityIdentifier("hub.bar.commands")
            }
            HStack(spacing: 10) {
                Button { model.attach() } label: { Image(systemName: "plus") }
                    .help("Attach files: copied into the project's .lampboard/allegati and cited")
                    .accessibilityIdentifier("hub.bar.attach")
                Button { if composer.text.isEmpty { composer.text = "/" } } label: { Text("/").font(.system(size: 13, weight: .semibold, design: .monospaced)) }
                    .help("The session's commands")
                    .disabled(bar.commands.isEmpty)
                Menu(modelTitle) {
                    Button("Session default") { model.choose(model: nil) }
                    Divider()
                    ForEach(HubBar.models, id: \.id) { item in Button(item.title) { model.choose(model: item.id) } }
                    Divider()
                    Picker("Effort", selection: Binding(get: { bar.effort ?? "" }, set: { model.choose(effort: $0.isEmpty ? nil : $0) })) {
                        Text("Session default").tag("")
                        ForEach(HubBar.efforts, id: \.self) { Text($0).tag($0) }
                    }
                }
                .fixedSize()
                .help("For this session only, from its next request")
                .accessibilityIdentifier("hub.bar.model")
                Menu(modeTitle) {
                    ForEach(HubBar.cycle, id: \.self) { mode in
                        Button(mode.title) { model.choose(mode: mode) }.disabled(!model.canReach(mode))
                    }
                }
                .fixedSize()
                .help("Plan through the session's command; the others with Shift+Tab, where LampBoard shows its terminal")
                .accessibilityIdentifier("hub.bar.mode")
                Button { model.toggleRemoteControl() } label: {
                    Label(bar.remote ? "Remote on" : "Remote", systemImage: "iphone")
                }
                .help("Claude Code's Remote Control, to follow this session from the phone")
                .disabled(!bar.names.contains("remote-control"))
                .accessibilityIdentifier("hub.bar.remote")
                Spacer()
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }

    /// The commands matching what is typed after `/`, while it is one word.
    private var matches: [ModReport.Command] {
        let text = composer.text
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let typed = text.dropFirst().lowercased()
        return Array(bar.commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }.prefix(8))
    }

    private var modelTitle: String {
        let name = bar.model.flatMap { id in HubBar.models.first { $0.id == id }?.title } ?? "Model: session's"
        return bar.effort.map { "\(name) · \($0)" } ?? name
    }

    private var modeTitle: String {
        if let reaching = bar.reaching { return "→ \(reaching.title)…" }
        return bar.mode?.title ?? "Mode"
    }
}
