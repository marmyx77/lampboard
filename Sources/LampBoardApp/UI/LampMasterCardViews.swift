import LampBoardCore
import SwiftUI

/// What a card can ask the panel to do. Built by `PanelController`, which owns
/// the rows, the windows and the dialogs.
struct LampMasterActions {
    /// Carries out a suggestion's action; the outcome is recorded as accepted.
    let perform: (LampMasterShown) -> Void
    /// Raises one session, by its short id.
    let open: (String) -> Void
    /// What to call a session, by its short id.
    let name: (String) -> String
    /// A suggested question put to its session without disturbing it (D82,
    /// D85): `nil` when that session's mod cannot answer, or sending is off.
    var askQuietly: (LampMasterShown) -> (@MainActor () async -> String)? = { _ in nil }
}

/// The cards, newest first, and what the last round did.
struct LampMasterCardsView: View {
    @ObservedObject var service: LampMasterService
    let actions: LampMasterActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if service.snapshot.open.isEmpty {
                        Text(empty)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(service.snapshot.open) { shown in
                        LampMasterCard(shown: shown, service: service, actions: actions)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private var empty: String {
        service.snapshot.running
            ? "LampMaster is reading the sessions…"
            : "Nothing to suggest. LampMaster speaks when one session knows what another needs, "
                + "when something waits or is stuck, when two sessions overlap, when work is done "
                + "and saved, or when a problem was solved before."
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Ask now") { service.request(.asked) }
                .disabled(service.snapshot.running)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let snapshot = service.snapshot
        let line = LampMasterLine.text(
            open: snapshot.open.count, last: snapshot.lastRound, running: snapshot.running,
            time: { $0.formatted(date: .omitted, time: .shortened) }
        )
        let tokens = snapshot.tokensToday.formatted(.number)
        return "\(line). Today: \(tokens) tokens of \(LampMasterSchedule.dailyTokenCap.formatted(.number))."
    }
}

/// One suggestion: what LampMaster saw, the proof, the sessions, and what to do.
struct LampMasterCard: View {
    let shown: LampMasterShown
    let service: LampMasterService
    let actions: LampMasterActions
    @State private var showsEvidence = false
    @State private var quietAnswer: String?
    @State private var asking = false

    private var suggestion: LampMasterAdvice.Suggestion { shown.suggestion }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LampMasterLine.title(suggestion.kind), systemImage: LampMasterLine.glyph(suggestion.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(StatusPalette.lampMasterTint)

            Text(suggestion.text)
                .fixedSize(horizontal: false, vertical: true)

            // The words a click would propose or ask, read before they go (D85).
            if let question = suggestion.action.question {
                Text("“\(question)”")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $showsEvidence) {
                Text(suggestion.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("Evidence").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(suggestion.sessions, id: \.self) { id in
                    Button(actions.name(id)) { actions.open(id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if let title = LampMasterLine.button(suggestion.action) {
                    Button(title) { actions.perform(shown) }
                        .buttonStyle(.borderedProminent)
                        .tint(StatusPalette.lampMasterTint)
                }
                // Costs a fork's tokens, so a click, every time; the session sees nothing.
                if let ask = actions.askQuietly(shown) {
                    Button(asking ? "Asking…" : "Ask without disturbing") {
                        asking = true
                        Task { @MainActor in
                            quietAnswer = await ask()
                            asking = false
                        }
                    }
                    .disabled(asking)
                }
                Button("Ignore") { service.react(to: shown.id, with: .ignored) }
                Spacer()
                Menu("More") {
                    Button("Wrong: this is not true") { service.react(to: shown.id, with: .wrong) }
                    Button("Don't suggest this kind again") { service.react(to: shown.id, with: .muted) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.small)

            if let quietAnswer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Its answer, from its conversation:").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(quietAnswer)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Answer: \(quietAnswer)")
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(StatusPalette.lampMasterTint.opacity(0.08)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
