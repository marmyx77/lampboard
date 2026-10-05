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
                        case .today: TodaySheet(lines: sheets.today)
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
