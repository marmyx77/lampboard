import Combine
import LampBoardCore
import SwiftUI

/// The extended window: conversations on the left, the selected one on the right.
struct ChatShellView: View {

    @ObservedObject var shell: ChatShell

    /// Reference moment for the timestamps. Ticks on its own so "3m ago" ages
    /// without waiting for a state change.
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Raises the VS Code window holding a session.
    let openInEditor: (SessionState) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Layout.sidebarWidth)
            Divider()
            conversation
        }
        .frame(minWidth: 720, minHeight: 420)
        .onReceive(clock) { now = $0 }
    }

    // MARK: - Left

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StatusPalette.timeColor)
                Spacer()
                Text("\(shell.rows.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StatusPalette.timeColor)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if shell.rows.isEmpty {
                VStack {
                    Spacer()
                    Text("No sessions.\nThey appear as soon as Claude Code signals one.")
                        .font(.system(size: 11))
                        .foregroundStyle(StatusPalette.timeColor)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(shell.rows) { row in
                            ChatSidebarRow(
                                row: row,
                                preview: shell.preview(for: row),
                                now: now,
                                isSelected: shell.selectedId == row.primary.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { shell.select(row: row) }
                            .contextMenu {
                                Button("Rename\u{2026}") { shell.rename(row: row) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Right

    @ViewBuilder
    private var conversation: some View {
        if let session = shell.selected {
            ChatView(session: session) {
                guard let state = state(of: session) else { return }
                openInEditor(state)
            }
            // Rebuilding on the id, not on the object, is what makes the scroll
            // position and the composer reset when you switch conversation rather
            // than carrying one project's half-typed sentence into another.
            .id(session.sessionId)
        } else {
            VStack {
                Spacer()
                Text("Pick a conversation on the left.")
                    .font(.system(size: 12))
                    .foregroundStyle(StatusPalette.timeColor)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func state(of session: ChatSession) -> SessionState? {
        shell.rows
            .flatMap(\.sessions)
            .first { $0.id == session.sessionId }
    }
}

/// One conversation in the left-hand list.
///
/// The shape a messenger taught everybody to read at a glance: a status mark, a
/// name, one line of what was last said, and the time on the right.
struct ChatSidebarRow: View {

    let row: ColumnRow
    let preview: String?
    let now: Date
    let isSelected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TrafficLightDot(status: row.status, calm: false, listening: row.listeners > 0)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let slot = row.slot {
                        Text("\(slot)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(StatusPalette.timeColor)
                            .monospacedDigit()
                    }
                    Text(row.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Text(RelativeTime.label(for: row.updatedAt, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(StatusPalette.timeColor)
                        .monospacedDigit()
                        .layoutPriority(1)
                }

                HStack(spacing: 6) {
                    // The line under the name is the last thing Claude said, which
                    // is what tells two projects apart when both are red.
                    Text(preview ?? row.status.label)
                        .font(.system(size: 10))
                        .foregroundStyle(StatusPalette.timeColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    if row.activeSubagents > 0 {
                        badge("×\(row.activeSubagents)")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
        .onHover { hovering = $0 }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(StatusPalette.badgeForeground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(StatusPalette.badgeBackground))
            .fixedSize()
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Rectangle().fill(Color.accentColor.opacity(0.22))
        } else if hovering {
            Rectangle().fill(Color.primary.opacity(0.07))
        } else {
            Color.clear
        }
    }
}
