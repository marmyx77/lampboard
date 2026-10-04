import LampBoardCore
import SwiftUI

/// "Waiting for you", above the rows (D74): one card per thing that needs the
/// user, most urgent first, at most four drawn and the rest counted.
///
/// Only in the wide panel. At 35 points there is room for a light and nothing
/// to say beside it, and the column already says which rows want somebody.
struct WaitingQueueSection: View {
    @ObservedObject var model: WaitingQueueModel

    var body: some View {
        if !model.cards.isEmpty || !model.resolved.isEmpty {
            VStack(spacing: Layout.rowSpacing) {
                ForEach(model.visible) { card in
                    WaitingCardView(card: card, selected: model.isSelected(card), armed: model.isArmed(card), resolved: false,
                                    onAnswer: { model.answer(card, $0) })
                        // Not on a held permission: a click on its Allow must
                        // never also raise the session (a review finding). `O`
                        // still opens it.
                        .onTapGesture { if card.call == nil { model.click(card) } }
                }
                ForEach(model.resolved) { card in
                    WaitingCardView(card: card, selected: false, armed: false, resolved: true)
                }
                if model.hiddenCount > 0 {
                    Text(model.hiddenCount == 1 ? "1 more waiting" : "\(model.hiddenCount) more waiting")
                        .font(.system(size: 10))
                        .foregroundStyle(StatusPalette.timeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                        .frame(height: Layout.issueStripHeight)
                }
            }
            .padding(.horizontal, Layout.panelPadding)
            .padding(.top, Layout.panelPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Waiting for you")
        }
    }
}

/// One card: the project and the kind of thing on the first line, what it asks
/// on the second.
struct WaitingCardView: View {
    let card: WaitingCard
    let selected: Bool
    let armed: Bool
    /// Answered somewhere else, shown for a moment before it goes.
    let resolved: Bool
    /// Allow or Deny, for an ask the panel holds.
    var onAnswer: (PermissionGate.Verdict) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Layout.dotSize, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(card.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        // A project's name keeps both ends; LampMaster's title
                        // is a sentence, and reads from its start.
                        .truncationMode(card.kind == .lampMaster ? .tail : .middle)
                    Spacer(minLength: 2)
                    if card.more > 0 {
                        Text("+\(card.more)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                    }
                    if card.call != nil, !resolved {
                        answerButton("Deny", .deny)
                        answerButton("Allow", .allow)
                    }
                }
                Text(resolved ? WaitingQueue.resolvedLine(card) : card.line)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
                    // What is allowed keeps both ends: `curl … | sh` must not
                    // lose its tail beside the Allow button.
                    .truncationMode(card.call == nil ? .tail : .middle)
                    .help(card.call == nil ? "" : card.line)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(height: Layout.queueCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(StatusPalette.blockWell)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? tint.opacity(0.7) : StatusPalette.blockEdge, lineWidth: 1)
                )
        )
        // Unarmed, it looks it: a card that looks ready must be.
        .opacity(resolved ? 0.45 : (armed ? 1 : 0.7))
        .contentShape(Rectangle())
        .accessibilityElement(children: card.call == nil || resolved ? .ignore : .contain)
        .accessibilityLabel("\(kindName): \(card.title), \(resolved ? WaitingQueue.resolvedLine(card) : card.line)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(card.call == nil || resolved ? "" : "Allow or Deny from the actions, or A and D")
        .accessibilityAction(named: "Allow") { if card.call != nil, !resolved { onAnswer(.allow) } }
        .accessibilityAction(named: "Deny") { if card.call != nil, !resolved { onAnswer(.deny) } }
    }

    /// Small, and inert until the card arms: a permission that pops up under
    /// the pointer is never answered by a click meant for something else.
    private func answerButton(_ title: String, _ verdict: PermissionGate.Verdict) -> some View {
        Button(title) { onAnswer(verdict) }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .frame(height: 13)
            .background(Capsule().fill(verdict == .allow ? tint.opacity(0.28) : StatusPalette.blockEdge))
            .disabled(!armed)
            .help(verdict == .allow ? "Allow this call (A)" : "Deny this call (D)")
            .accessibilityLabel(verdict == .allow ? "Allow" : "Deny")
    }

    private var glyph: String {
        switch card.kind {
        case .permission: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .stuck: return "hourglass"
        case .failed: return "xmark.octagon.fill"
        case .ready, .readyGroup: return "text.bubble.fill"
        case .lampMaster: return "sparkle"
        }
    }

    private var tint: Color {
        switch card.kind {
        case .permission, .question: return StatusPalette.color(for: .awaiting)
        case .stuck: return StatusPalette.color(for: .working)
        case .failed: return StatusPalette.color(for: .failed)
        case .ready, .readyGroup: return StatusPalette.color(for: .ready)
        case .lampMaster: return StatusPalette.lampMasterTint
        }
    }

    private var kindName: String {
        switch card.kind {
        case .permission: return "Permission"
        case .question: return "Question"
        case .stuck: return "Possibly stuck"
        case .failed: return "Failed"
        case .ready: return "Answer to read"
        case .readyGroup: return "Answers to read"
        case .lampMaster: return "LampMaster suggests"
        }
    }
}
