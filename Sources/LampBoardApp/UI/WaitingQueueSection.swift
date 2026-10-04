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
                    WaitingCardView(card: card, selected: model.isSelected(card), armed: model.isArmed(card), resolved: false)
                        .onTapGesture { model.click(card) }
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
                }
                Text(resolved ? "Resolved elsewhere" : card.line)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kindName): \(card.title), \(resolved ? "resolved elsewhere" : card.line)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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
