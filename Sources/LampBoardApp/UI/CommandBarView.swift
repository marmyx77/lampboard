import LampBoardCore
import SwiftUI

/// The bar at the top of the wide panel (UX §2, D77): one field, and under it
/// what it finds and LampMaster's answer. `⌘K` focuses it while the panel holds
/// the keyboard; `↑` `↓` choose, `⏎` opens, `Esc` empties it.
struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Layout.rowSpacing) {
            if model.isEditing {
                field
            } else {
                Button { model.focus() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                        Text("Search · @session · ?LampMaster").font(.system(size: 11, design: .rounded))
                        Spacer(minLength: 4)
                        Text("⌘K").font(.system(size: 10, design: .rounded)).monospacedDigit()
                    }
                    .foregroundStyle(StatusPalette.timeColor)
                    .padding(.horizontal, 7)
                    .frame(height: Layout.barField)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StatusPalette.blockWell))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search sessions and actions")
            }

            if !model.shownResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.shownResults.enumerated()), id: \.element.id) { index, result in
                        resultRow(result, selected: index == model.selected)
                            .onTapGesture { model.choose(result) }
                    }
                }
            }

            if let answer = model.shownAnswer {
                ScrollView {
                    Text(answer)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: Layout.barAnswer)
            }
        }
        .padding(.horizontal, Layout.panelPadding)
        .padding(.top, Layout.panelPadding)
        .onChange(of: focused) { _, now in if !now { model.blurred() } }
        .onChange(of: model.focusTick) { _, _ in focused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StatusPalette.timeColor)
            TextField("Search · @session · ?LampMaster", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .rounded))
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { model.submit() }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onExitCommand { model.clear() }
                .accessibilityLabel("Search sessions and actions")
            Button { model.clear() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StatusPalette.timeColor)
            .accessibilityLabel("Close the search")
        }
        .padding(.horizontal, 7)
        .frame(height: Layout.barField)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StatusPalette.blockWell))
    }

    private func resultRow(_ result: CommandBar.Result, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Group {
                switch result.kind {
                case .session: TrafficLightDot(status: result.status ?? .idle, calm: true, listening: false).scaleEffect(0.7)
                case .action: Image(systemName: "gearshape").font(.system(size: 9))
                case .ask: Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(StatusPalette.lampMasterTint)
                }
            }
            .frame(width: Layout.dotSize)
            Text(result.title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
            if !result.detail.isEmpty {
                Text(result.detail).font(.system(size: 10)).foregroundStyle(StatusPalette.timeColor).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: Layout.barResult)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.detail.isEmpty ? result.title : "\(result.title), \(result.detail)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
