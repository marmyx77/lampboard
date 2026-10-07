import LampBoardCore
import SwiftUI

/// A permission or question the panel holds, drawn under its own row (U2).
///
/// It used to be a card above the rows, in a queue that also repeated every
/// green and red row underneath it: the «notification of the notification» the
/// 1.1 review found. The ask is the one thing in that queue the row could not do,
/// so it moved into the row, and the rest of the queue went. One line: what the
/// call would do, what it would touch when that is worth a warning, and Deny and
/// Allow — or the question's options — inert until the line has been on screen
/// long enough to be read (`WaitingQueue.armDelay`).
struct InlineAskView: View {
    @ObservedObject var queue: WaitingQueueModel
    /// The row's sessions: the first one with an ask held draws it.
    let sessionIds: [String]

    var body: some View {
        if let card = sessionIds.lazy.compactMap({ queue.held[$0] }).first {
            line(card, resolved: false)
        } else if let card = sessionIds.lazy.compactMap({ queue.resolvedHeld[$0] }).first {
            line(card, resolved: true)
        }
    }

    private func line(_ card: WaitingCard, resolved: Bool) -> some View {
        let armed = !resolved && queue.isArmed(card)
        let tint = StatusPalette.color(for: .awaiting)
        return HStack(spacing: 6) {
            Image(systemName: card.options.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(resolved ? WaitingQueue.resolvedLine(card) : card.line)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.75))
                .lineLimit(1)
                // `curl … | sh` must keep its tail beside the Allow button.
                .truncationMode(.middle)
                .tooltip(card.line)
            if let impact = card.impact, !resolved, PermissionImpact.warns(impact) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StatusPalette.color(for: .failed))
                    .tooltip(impact)
                    .accessibilityLabel(impact)
            }
            Spacer(minLength: 4)
            if !resolved {
                if card.options.isEmpty {
                    button("Deny", fill: StatusPalette.blockEdge, armed: armed, help: "Deny this call (D)") {
                        queue.answer(card, .deny)
                    }
                    button("Allow", fill: tint.opacity(0.32), armed: armed, help: "Allow this call (A)") {
                        queue.answer(card, .allow)
                    }
                } else {
                    ForEach(Array(card.options.prefix(3).enumerated()), id: \.offset) { index, option in
                        button("\(index + 1) " + Self.short(option), fill: StatusPalette.blockEdge, armed: armed,
                               help: "\(option) (\(index + 1))") { queue.choose(card, index) }
                    }
                }
            }
        }
        // Under the name, not under the light: the light is the row's, the line
        // belongs to what the row is asking.
        .padding(.leading, Layout.dotSize + Layout.dotToRing + Layout.contextRingSize + 13)
        .padding(.trailing, 6)
        .frame(height: Layout.inlineAsk)
        .opacity(resolved ? 0.45 : (armed ? 1 : 0.7))
        .accessibilityElement(children: resolved ? .ignore : .contain)
        .accessibilityLabel((card.options.isEmpty ? "Permission: " : "Question: ")
            + (resolved ? WaitingQueue.resolvedLine(card) : card.line) + (card.impact.map { ", \($0)" } ?? ""))
    }

    private func button(_ title: String, fill: Color, armed: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            Diagnostics.log("inline ask: \(title) clicked, armed \(armed)")
            action()
        }
            .buttonStyle(.plain)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(Capsule().fill(fill))
            .disabled(!armed)
            .tooltip(help)
            .accessibilityLabel(help)
    }

    /// A question's option, short enough to sit beside two others; the whole
    /// label is in the tooltip.
    private static func short(_ option: String) -> String {
        option.count > 12 ? String(option.prefix(11)) + "…" : option
    }
}
