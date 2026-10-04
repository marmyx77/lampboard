import LampBoardCore
import SwiftUI

/// The Plancia (UX §5, D79): the session in focus, open beside the list toward
/// the middle of the screen. Its conversation is the chat window's own view;
/// above it, the pin that keeps it open and the way back to the panel.
struct PlanciaView: View {
    @ObservedObject var model: PlanciaModel
    let openInEditor: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Plancia")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(StatusPalette.timeColor)
                Spacer()
                Button { model.pinned.toggle() } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.pinned ? Color.primary : StatusPalette.timeColor)
                .tooltip(model.pinned ? "Pinned open. Click to let it close by itself." : "Keep the Plancia open")
                .accessibilityLabel(model.pinned ? "Unpin the Plancia" : "Pin the Plancia open")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StatusPalette.timeColor)
                .tooltip("Back to the panel (Esc)")
                .accessibilityLabel("Close the Plancia")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)

            if let thread = model.thread, let id = model.sessionId {
                ChatView(session: thread) { openInEditor(id) }
                    .id(id)
            } else {
                Spacer()
            }
        }
        .frame(width: PanelDepth.plancia.width - PanelDepth.panel.width - 1)
    }
}
