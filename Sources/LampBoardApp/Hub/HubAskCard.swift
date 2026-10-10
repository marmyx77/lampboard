import LampBoardCore
import SwiftUI

/// What the open session asks, in its thread (the proposal's `.ask`): a
/// permission the panel holds with Allow and Deny and the time it has left, a
/// question with its options, or, when the panel holds nothing, a line saying
/// it asks in its own window. One card, the first that waits for this session.
struct HubAskCard: View {
    @ObservedObject var queue: WaitingQueueModel
    let sessionId: String
    let asking: Bool
    let openRealWindow: () -> Void

    var body: some View {
        if let card = queue.cards.first(where: { $0.sessionIds.contains(sessionId) && ($0.kind == .permission || $0.kind == .question) }) {
            held(card)
        } else if asking {
            frame {
                Text("Asking in its own window").font(.system(size: 13, weight: .semibold))
                Text("The panel holds nothing for this one: answer it where the session runs.")
                    .font(.system(size: 11)).foregroundStyle(HubPalette.muted)
                Button("Open the real window", action: openRealWindow).buttonStyle(HubButtonStyle())
            }
        }
    }

    @ViewBuilder private func held(_ card: WaitingCard) -> some View {
        let parts = card.line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let tool = parts.count == 2 ? parts[0] : (card.kind == .question ? "Question" : "Permission")
        let detail = parts.count == 2 ? parts[1] : card.line
        frame {
            Text(card.kind == .question ? card.line : "Permission: \(tool)").font(.system(size: 13, weight: .semibold))
            if card.kind == .permission {
                Text(detail).font(HubPalette.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let impact = card.impact { Text(impact).font(.system(size: 11)).foregroundStyle(HubPalette.muted) }
            }
            if card.call != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, PermissionGate.answerWithin - context.date.timeIntervalSince(card.appearedAt))
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(HubPalette.line)
                                Capsule().fill(HubPalette.amber).frame(width: proxy.size.width * left / PermissionGate.answerWithin)
                            }
                        }
                        .frame(height: 4)
                        HStack(spacing: 8) {
                            if card.options.isEmpty {
                                Button("Allow") { queue.answer(card, .allow) }.buttonStyle(HubButtonStyle(kind: .primary))
                                    .accessibilityIdentifier("hub.ask.allow")
                                Button("Deny") { queue.answer(card, .deny) }.buttonStyle(HubButtonStyle())
                                    .accessibilityIdentifier("hub.ask.deny")
                            } else {
                                ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                                    Button(option) { queue.choose(card, index) }.buttonStyle(HubButtonStyle(kind: index == 0 ? .primary : .plain))
                                }
                            }
                            Spacer()
                            Text("\(Int(left.rounded(.up))) s").font(.system(size: 11)).monospacedDigit().foregroundStyle(HubPalette.muted)
                        }
                        .disabled(!queue.isArmed(card) || left <= 0)
                    }
                }
            } else {
                Text("It asks in its own window.").font(.system(size: 11)).foregroundStyle(HubPalette.muted)
                Button("Open the real window", action: openRealWindow).buttonStyle(HubButtonStyle())
            }
        }
        .accessibilityIdentifier("hub.ask")
    }

    private func frame<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(HubPalette.amberSoft))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HubPalette.amber, lineWidth: 1))
            .foregroundStyle(HubPalette.ink)
    }
}
