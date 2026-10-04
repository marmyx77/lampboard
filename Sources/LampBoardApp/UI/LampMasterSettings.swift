import LampBoardCore
import SwiftUI

/// LampMaster's section of Settings: the switch, and what it costs, said
/// before it is pressed.
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

    var body: some View {
        Section {
            Toggle("Let LampMaster look at the sessions", isOn: Binding(
                get: { service.snapshot.enabled },
                set: { service.setEnabled($0) }
            ))

            Text("""
            Once an hour LampMaster reads this Mac's Claude Code sessions — the last prompts \
            and answers, the files written, what failed and what was saved — and asks Claude, \
            with your own Claude Code sign-in, for at most three suggestions: a session that \
            knows what another needs, one that waits or is stuck, two on the same work, work \
            done and saved, a problem solved before. That sends pieces of your conversations \
            to Anthropic and spends your allowance: about 7,000 tokens a round, never more \
            than \(LampMasterSchedule.dailyTokenCap.formatted(.number)) a day. A round with \
            nothing new is skipped for free. Nothing is done without your click.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker("Every", selection: $minutes) {
                ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            .onChange(of: minutes) { _, value in preferences.lampMasterInterval = TimeInterval(value * 60) }

            Picker("Model", selection: $model) {
                Text("Opus — finds the links between sessions").tag("opus")
                Text("Sonnet — faster and cheaper").tag("sonnet")
            }
            .onChange(of: model) { _, value in preferences.lampMasterModel = value }

            if !muted.isEmpty {
                ForEach(muted.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                    HStack {
                        Text("Not suggested: " + LampMasterLine.title(kind))
                        Spacer()
                        Button("Suggest again") {
                            // Read fresh: a card in the other window may have muted
                            // a kind since this section was drawn.
                            var current = preferences.lampMasterMuted
                            current.remove(kind)
                            preferences.lampMasterMuted = current
                            muted = current
                        }
                    }
                }
            }
        } header: {
            Text("LampMaster")
        }
        // A card's "don't suggest this kind" publishes the service's state; the
        // list here follows it rather than keeping what it saw when it opened.
        .onReceive(service.$snapshot) { _ in muted = preferences.lampMasterMuted }
    }
}
