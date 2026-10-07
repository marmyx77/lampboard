import LampBoardCore
import SwiftUI

/// Settings › LampMaster: the switch, and what it costs, said before it is
/// pressed. Names from `SettingsCatalog` (U3).
///
/// The sentence is on screen whether or not the switch is on, because the
/// choice it describes — pieces of conversations sent to Anthropic, the
/// allowance spent — has to be read before it is made, not after (D60).
struct LampMasterSettings: View {
    @ObservedObject var service: LampMasterService
    private let preferences = Preferences()

    @State private var minutes = Int(Preferences().lampMasterInterval / 60)
    @State private var model = Preferences().lampMasterModel
    @State private var muted = Preferences().lampMasterMuted
    @State private var callable = LampMasterSetup.isRegistered
    @State private var setupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingToggle(id: .lampMaster, isOn: service.snapshot.enabled) { service.setEnabled($0) }

            Text("""
            Once an hour — and at once, up to six times a day, when a session starts repeating \
            a failure or stops moving — LampMaster reads this Mac's Claude Code sessions — the \
            last prompts and answers, the files written, what failed and what was saved — and asks Claude, \
            with your own Claude Code sign-in, for at most three suggestions: a session that \
            knows what another needs, one that waits or is stuck, two on the same work, work \
            done and saved, a problem solved before. That sends pieces of your conversations \
            to Anthropic and spends your allowance: about \(7_000.formatted(.number)) tokens a round, never more \
            than \(LampMasterSchedule.dailyTokenCap.formatted(.number)) a day. A round with \
            nothing new is skipped for free. Nothing is done without your click.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SettingToggle(id: .lampMasterAsk, isOn: callable) { wanted in Task { await setCallable(wanted) } }
            Text("""
            Adds lampmaster to Claude Code as an MCP server, for all your projects. A session can \
            then ask who else is on its files, who worked on a topic, who hit the same error — \
            answered from this Mac, at no cost — and put a question to LampMaster, which runs a \
            model like a round does, at most twenty times an hour. The answers describe other \
            sessions; they never carry what those sessions wrote. Sessions already open see it \
            after a restart.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let setupError {
                Text(setupError).font(.caption).foregroundStyle(.red)
            }

            Picker(SettingsCatalog.item(.lampMasterEvery).label, selection: $minutes) {
                ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            .onChange(of: minutes) { _, value in preferences.lampMasterInterval = TimeInterval(value * 60) }

            Picker(SettingsCatalog.item(.lampMasterModel).label, selection: $model) {
                Text("Opus — finds the links between sessions").tag("opus")
                Text("Sonnet — faster and cheaper").tag("sonnet")
            }
            .onChange(of: model) { _, value in preferences.lampMasterModel = value }

            if !muted.isEmpty {
                ForEach(muted.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not suggested: " + LampMasterLine.title(kind))
                            if let why = preferences.lampMasterAutoMuted[kind] {
                                Text("Switched off by itself: " + why).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Suggest again") {
                            // Read fresh: a card in the other window may have muted
                            // a kind since this section was drawn.
                            var current = preferences.lampMasterMuted
                            current.remove(kind)
                            preferences.lampMasterMuted = current
                            preferences.lampMasterAutoMuted[kind] = nil
                            // Its record counts from now (D5).
                            preferences.lampMasterAskedBack[kind] = Date()
                            muted = current
                        }
                    }
                }
            }
            if muted.isEmpty {
                SettingRow(id: .lampMasterMuted) { Text("None").foregroundStyle(.secondary) }
            }
        }
        // A card's "don't suggest this kind" publishes the service's state; the
        // list here follows it rather than keeping what it saw when it opened.
        .onReceive(service.$snapshot) { _ in muted = preferences.lampMasterMuted }
    }

    /// Runs `claude mcp add` or `remove` off the main thread: it is a process,
    /// and the Settings window must not freeze while it starts.
    private func setCallable(_ wanted: Bool) async {
        let port = service.port
        let outcome = await Task.detached {
            wanted ? LampMasterSetup.register(port: port) : LampMasterSetup.unregister()
        }.value
        callable = LampMasterSetup.isRegistered
        if case .failed(let reason) = outcome { setupError = reason } else { setupError = nil }
    }
}
