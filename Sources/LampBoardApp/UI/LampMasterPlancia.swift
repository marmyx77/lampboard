import LampBoardCore
import SwiftUI

/// LampMaster's Plancia (UX §4, D96, D97): its cards, and beside them what it
/// did today, the frame its last round was given, and what the rounds cost.
/// Read from its files each time a sheet is drawn.
struct LampMasterPlanciaContent: View {
    @ObservedObject var service: LampMasterService
    let actions: LampMasterActions

    enum Sheet: String, CaseIterable, Identifiable {
        case suggestions = "Suggestions", today = "Today", frame = "Frame", cost = "Cost"
        var id: String { rawValue }
    }

    @State var sheet = Sheet.suggestions

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sheet) {
                ForEach(Sheet.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            switch sheet {
            case .suggestions: LampMasterCardsView(service: service, actions: actions)
            default:
                // Read again whenever the service publishes: a round, a reaction.
                let sheets = service.sheets()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch sheet {
                        case .today:
                            ConversationBox(service: service)
                            AskedToday(lines: service.askedToday())
                            TodaySheet(lines: sheets.today)
                        case .frame: FrameSheetView(sheet: sheets.frame)
                        default: CostSheetView(sheet: sheets.cost, interval: service.preferences.lampMasterInterval,
                                               model: service.preferences.lampMasterModel)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}

/// Asking LampMaster from its Plancia (D118): a question, its answer, and a
/// follow-up read against them, until *New conversation*.
private struct ConversationBox: View {
    @ObservedObject var service: LampMasterService
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(service.conversation) { exchange in
                VStack(alignment: .leading, spacing: 3) {
                    Text(exchange.question).font(.callout.weight(.semibold))
                    Text(exchange.answer).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let asked = service.conversing {
                Text(asked).font(.callout.weight(.semibold))
                Text("LampMaster is reading your sessions…").font(.callout).foregroundStyle(.secondary)
            }
            if let error = service.conversationError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                TextField(service.conversation.isEmpty ? "Ask LampMaster about your sessions" : "Follow up",
                          text: $typed, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                    .disabled(!service.snapshot.enabled)
                Button("Ask", action: ask)
                    .disabled(!service.snapshot.enabled || service.conversing != nil
                              || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text(service.snapshot.enabled
                     ? "Answered from your sessions and the search index, with Sonnet, within today's tokens."
                     : "Switch LampMaster on in Settings to ask it.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !service.conversation.isEmpty {
                    Button("New conversation") { service.newConversation() }
                        .buttonStyle(.link).font(.caption).disabled(service.conversing != nil)
                }
            }
        }
        Divider()
    }

    private func ask() {
        guard service.conversing == nil else { return }
        let asked = typed
        typed = ""
        // Refused or failed: the question comes back, unless something new was typed.
        service.converse(asked) { back in if typed.isEmpty { typed = back } }
    }
}

/// Who asked LampMaster what today: the sessions through `/lampmaster` and
/// the tool, and the person from the panel.
private struct AskedToday: View {
    let lines: [LampMasterSheets.AskLine]

    var body: some View {
        if !lines.isEmpty {
            Text("Asked today").font(.caption.weight(.semibold))
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(line.who).font(.caption.weight(.semibold))
                        Spacer()
                        Text(line.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(line.question).font(.callout).lineLimit(2)
                    Text(line.answer ?? "No answer.").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Divider()
            }
        }
    }
}

private struct TodaySheet: View {
    let lines: [LampMasterSheets.TodayLine]

    var body: some View {
        if lines.isEmpty {
            Text("No suggestion today.").foregroundStyle(.secondary)
        }
        ForEach(lines) { line in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(LampMasterLine.title(line.kind)).font(.caption.weight(.semibold))
                    Spacer()
                    Text(line.at.formatted(date: .omitted, time: .shortened) + " · " + line.outcome)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(line.text).font(.callout).lineLimit(3)
            }
            Divider()
        }
    }
}

private struct FrameSheetView: View {
    let sheet: LampMasterSheets.FrameSheet?

    var body: some View {
        if let sheet {
            Text("What the last round saw: \(sheet.sessions.count) sessions, about \(sheet.estimatedTokens.formatted(.number)) tokens.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(sheet.quota, id: \.self) { Text($0).font(.caption) }
            ForEach(sheet.sessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.project) · \(session.id) · \(session.host) · \(session.state)")
                        .font(.callout.weight(.medium))
                    ForEach(session.signals, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                    if session.precedents > 0 {
                        Text("\(session.precedents) precedent\(session.precedents == 1 ? "" : "s") found in the index")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
        } else {
            Text("No round has run yet: the frame shows once one has.").foregroundStyle(.secondary)
        }
    }
}

private struct CostSheetView: View {
    let sheet: LampMasterSheets.CostSheet
    let interval: TimeInterval
    let model: String

    var body: some View {
        Text("Today: \(sheet.ran) round\(sheet.ran == 1 ? "" : "s") ran, \(sheet.skipped) skipped, \(sheet.failed) failed · "
             + "\(sheet.tokensToday.formatted(.number)) of \(sheet.cap.formatted(.number)) tokens"
             + (sheet.costToday > 0 ? String(format: " · $%.2f", sheet.costToday) : ""))
            .font(.callout)
        Text("Every \(Int(interval / 60)) minutes, with \(model.capitalized).").font(.caption).foregroundStyle(.secondary)
        Divider()
        Text("Last rounds").font(.caption.weight(.semibold))
        if sheet.lastRuns.isEmpty { Text("None yet.").font(.caption).foregroundStyle(.secondary) }
        ForEach(sheet.lastRuns, id: \.at) { round in
            Text(round.at.formatted(date: .abbreviated, time: .shortened) + " · " + round.outcome.rawValue
                 + " · \(round.tokens.formatted(.number)) tokens" + (round.costUSD.map { String(format: " · $%.3f", $0) } ?? "")
                 + (round.model.map { " · " + $0 } ?? ""))
                .font(.caption)
        }
        Divider()
        Text("Kinds, over two weeks").font(.caption.weight(.semibold))
        ForEach(sheet.kinds) { kind in
            VStack(alignment: .leading, spacing: 1) {
                Text(LampMasterLine.title(kind.kind) + " · " + (kind.on ? "on" : "off")
                     + (kind.counted > 0 ? " · \(kind.accepted) of \(kind.counted) accepted" : ""))
                    .font(.caption)
                if let why = kind.switchedOffBecause {
                    Text("Switched off by itself: " + why).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
