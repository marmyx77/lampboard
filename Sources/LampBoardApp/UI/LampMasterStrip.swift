import LampBoardCore
import SwiftUI

/// LampMaster's line under the column: what the last round found, and the way
/// into its cards.
///
/// One line of fixed height, counted by `PanelMetrics.height`, and only while
/// LampMaster is switched on. The cards open in a window of their own rather
/// than inside the panel: they hold sentences of any length, and a panel sized
/// by a formula cannot make room for text it has not measured.
///
/// It never blinks. A suggestion is advice, not a session waiting; the column
/// already has a colour for that.
struct LampMasterStrip: View {
    @ObservedObject var service: LampMasterService
    let compact: Bool
    let open: () -> Void

    var body: some View {
        if service.snapshot.enabled {
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StatusPalette.lampMasterTint)
                    if !compact {
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.primary.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                    }
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(StatusPalette.lampMasterTint)
                    }
                }
                .padding(.horizontal, compact ? 4 : Layout.panelPadding + 6)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .frame(height: Layout.issueStripHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip(line + ". Click for LampMaster's cards.")
            .contextMenu {
                Button("Ask LampMaster now") { service.request(.asked) }
            }
        }
    }

    private var count: Int { service.snapshot.open.count }

    private var line: String {
        LampMasterLine.text(
            open: count, last: service.snapshot.lastRound, running: service.snapshot.running,
            time: { $0.formatted(date: .omitted, time: .shortened) }
        )
    }
}
