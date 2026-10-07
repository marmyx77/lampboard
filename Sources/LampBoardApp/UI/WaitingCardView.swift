import LampBoardCore
import SwiftUI

/// One card: the project and the kind of thing on the first line, what it asks
/// on the second. Drawn at the top of a session's Plancia (D79); in the column a
/// held ask is a line under its row instead (`InlineAskView`, U2).
struct WaitingCardView: View {
    let card: WaitingCard
    let selected: Bool
    let armed: Bool
    /// Answered somewhere else, shown for a moment before it goes.
    let resolved: Bool
    /// Allow or Deny, for an ask the panel holds.
    var onAnswer: (PermissionGate.Verdict) -> Void = { _ in }
    /// One of a held question's options (D86).
    var onChoose: (Int) -> Void = { _ in }

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
                        // The project's name before what the call would do.
                        .layoutPriority(1)
                        // A project's name keeps both ends; LampMaster's title
                        // is a sentence, and reads from its start.
                        .truncationMode(card.kind == .lampMaster ? .tail : .middle)
                    Spacer(minLength: 2)
                    // What it would do, beside the buttons that let it (D87).
                    if let impact = card.impact, !resolved {
                        Text(impact)
                            .font(.system(size: 9, weight: PermissionImpact.warns(impact) ? .bold : .regular))
                            .foregroundStyle(PermissionImpact.warns(impact) ? StatusPalette.color(for: .failed) : StatusPalette.timeColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tooltip(impact)
                    }
                    if card.more > 0 {
                        Text("+\(card.more)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                    }
                    if card.call != nil, !resolved {
                        if card.options.isEmpty {
                            answerButton("Deny", .deny)
                            answerButton("Allow", .allow)
                        } else {
                            ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                                optionButton(index, option)
                            }
                        }
                    }
                }
                Text(resolved ? WaitingQueue.resolvedLine(card) : card.line)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
                    // What is allowed keeps both ends: `curl … | sh` must not
                    // lose its tail beside the Allow button.
                    .truncationMode(card.call == nil ? .tail : .middle)
                    .tooltip(card.line)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(height: Layout.planciaCard)
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
        .accessibilityLabel("\(kindName): \(card.title), \(resolved ? WaitingQueue.resolvedLine(card) : card.line)"
            + (card.impact.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(card.call == nil || resolved ? ""
            : card.options.isEmpty ? "Allow or Deny from the actions, or A and D" : "Choose an option, or press its number")
        .accessibilityAction(named: "Allow") { if card.call != nil, card.options.isEmpty, !resolved { onAnswer(.allow) } }
        .accessibilityAction(named: "Deny") { if card.call != nil, card.options.isEmpty, !resolved { onAnswer(.deny) } }
    }

    /// An option of a held question: its digit and a short label, the whole
    /// label in the tooltip; inert until the card arms, like Allow.
    private func optionButton(_ index: Int, _ option: String) -> some View {
        Button("\(index + 1) \(option.count > 10 ? String(option.prefix(9)) + "…" : option)") { onChoose(index) }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .frame(height: 13)
            .background(Capsule().fill(StatusPalette.blockEdge))
            .disabled(!armed)
            .tooltip("\(option) (\(index + 1))")
            .accessibilityLabel(option)
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
            .tooltip(verdict == .allow ? "Allow this call (A)" : "Deny this call (D)")
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
