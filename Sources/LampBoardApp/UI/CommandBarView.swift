import LampBoardCore
import SwiftUI

/// The bar at the top of the wide panel (UX §2, D77): one field, and under it
/// what it finds and LampMaster's answer. `⌘K` focuses it while the panel holds
/// the keyboard; `↑` `↓` choose, `⏎` opens, `Esc` empties it.
struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel
    /// What waits, counted at the bar's end (U2); a click shows only those rows.
    var queue: WaitingQueueModel? = nil
    var onlyWaiting = false
    var toggleOnlyWaiting: () -> Void = {}
    /// LampMaster's star at the bar's end (U2), while it is switched on.
    var lampMaster: LampMasterService? = nil
    var openLampMaster: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Layout.rowSpacing) {
            if model.isEditing {
                field
            } else {
                HStack(spacing: 6) {
                    Button { model.focus() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                            Text("Search").font(.system(size: 11, design: .rounded))
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search sessions and actions")
                    if let queue { BarCount(queue: queue, onlyWaiting: onlyWaiting, toggle: toggleOnlyWaiting) }
                    if let lampMaster { LampMasterStar(service: lampMaster, open: openLampMaster) }
                    Text("⌘K").font(.system(size: 10, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(StatusPalette.timeColor)
                .padding(.horizontal, 7)
                .frame(height: Layout.barField)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StatusPalette.blockWell))
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
                    if !model.weekTiles.isEmpty { WeekTiles(tiles: model.weekTiles) }
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
                case .send: Image(systemName: "paperplane").font(.system(size: 9))
                case .askSession: Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 9))
                case .conversation: Image(systemName: "clock.arrow.circlepath").font(.system(size: 9))
                case .handoff: Image(systemName: "arrow.right.doc.on.clipboard").font(.system(size: 9))
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

/// The week's figures as tiles (UX §7, R5): a number large, its label small,
/// three to a line.
private struct WeekTiles: View {
    let tiles: [WeekSummary.Tile]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(tile.label)
                        .font(.system(size: 9))
                        .foregroundStyle(StatusPalette.timeColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(StatusPalette.badgeBackground))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, 6)
    }
}

/// «1 needs you · 2 to read» at the end of the bar (U2): the count the queue's
/// cards used to make by being there. A click shows only those rows; a second one
/// shows them all again.
private struct BarCount: View {
    @ObservedObject var queue: WaitingQueueModel
    let onlyWaiting: Bool
    let toggle: () -> Void

    var body: some View {
        if let line = queue.countLine {
            Button(action: toggle) {
                Text(line)
                    .font(.system(size: 10, weight: onlyWaiting ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(onlyWaiting ? Color.primary.opacity(0.9) : StatusPalette.timeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .tooltip(onlyWaiting ? "Showing only these. Click to show every row." : "Click to show only these rows.")
            .accessibilityLabel(line)
        }
    }
}

/// LampMaster, the reviewer, as a star at the end of the bar (U2): dim while it
/// has nothing to say, lit with a number when it has suggestions. It used to be a
/// row of its own, thirty-eight points tall, that mostly said «Nothing to report».
/// A click opens its view beside the list, where the suggestions and their
/// actions are.
private struct LampMasterStar: View {
    @ObservedObject var service: LampMasterService
    let open: () -> Void

    var body: some View {
        if service.snapshot.enabled {
            let count = service.snapshot.open.count
            Button(action: open) {
                HStack(spacing: 2) {
                    Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
                    if count > 0 { Text("\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit() }
                }
                .foregroundStyle(count > 0 ? StatusPalette.lampMasterTint : StatusPalette.timeColor.opacity(0.7))
            }
            .buttonStyle(.plain)
            .tooltip("LampMaster, the reviewer: " + LampMasterLine.text(
                open: count, last: service.snapshot.lastRound, running: service.snapshot.running,
                time: { $0.formatted(date: .omitted, time: .shortened) }) + ". Click to open it beside the list.")
            .accessibilityLabel(count > 0 ? "LampMaster, \(count) suggestions" : "LampMaster")
            .contextMenu { Button("Ask LampMaster now") { service.request(.asked) } }
        }
    }
}
