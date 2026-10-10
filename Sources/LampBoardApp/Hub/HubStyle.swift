import AppKit
import SwiftUI

/// The Hub's colours and controls, as the LampBoard 2 proposal draws them
/// (artifact 51hg2GFuHpTbttKa6rYhNe, dark): one dark window whatever the Mac
/// is, like the panel whose rows it shows (D150).
enum HubPalette {
    static let window = Color(hub: 0x14181C)
    static let panel = Color(hub: 0x1C2227)
    static let soft = Color(hub: 0x252C32)
    static let line = Color(hub: 0x2E363D)
    static let ink = Color(hub: 0xE4E8EB)
    static let muted = Color(hub: 0x9AA5AE)
    static let accent = Color(hub: 0x7FB0DE)
    static let accentSoft = Color(hub: 0x22364A)
    static let amber = Color(hub: 0xE9B04A)
    static let amberSoft = Color(hub: 0x3B3020)
    static let red = Color(hub: 0xEF7466)
    static let green = Color(hub: 0x5CC082)
    static let read = Color(hub: 0x8A5CC2)
    static let codex = Color(hub: 0x46C4B8)
    static let codexSoft = Color(hub: 0x173A37)

    static let nsWindow = NSColor(srgbRed: 0x1C / 255, green: 0x22 / 255, blue: 0x27 / 255, alpha: 1)
    static let appearance = NSAppearance(named: .darkAqua)

    /// The body text of the conversation and the composer.
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

extension Color {
    init(hub hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The proposal's `.btn`: bordered, filled for the main action, red for Stop.
struct HubButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, danger }
    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        HubButtonBody(configuration: configuration, kind: kind)
    }

    private struct HubButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: kind == .primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(stroke, lineWidth: 1))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }

        private var fill: Color { kind == .primary ? HubPalette.accent : HubPalette.panel }
        private var stroke: Color {
            switch kind {
            case .primary: return HubPalette.accent
            case .danger: return HubPalette.red
            case .plain: return HubPalette.line
            }
        }
        private var foreground: Color {
            switch kind {
            case .primary: return HubPalette.panel
            case .danger: return HubPalette.red
            case .plain: return HubPalette.ink
            }
        }
    }
}

/// The proposal's `.pillbtn`: the bar's model, mode and Remote Control.
struct HubPillStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(on ? HubPalette.panel : HubPalette.ink)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Capsule().fill(on ? HubPalette.accent : HubPalette.soft))
            .overlay(Capsule().stroke(on ? HubPalette.accent : HubPalette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// The proposal's `.ico`: a square icon button in the bar.
struct HubIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(HubPalette.muted)
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A session's lamp, as the rows draw it.
struct HubLamp: View {
    let color: Color
    var size: CGFloat = 11

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).shadow(color: color.opacity(0.7), radius: 3)
    }
}

/// A list in a little window above the bar (the proposal's `.pop`): a title,
/// an optional filter, the choices and a line on where they go.
struct HubPopList<Item: Identifiable>: View {
    let title: String
    let items: [Item]
    var filter: Binding<String>? = nil
    var note: String? = nil
    let label: (Item) -> (title: String, detail: String, current: Bool)
    let pick: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HubPalette.ink)
                if let filter {
                    TextField("Filter…", text: filter).textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(HubPalette.window))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(HubPalette.line))
                }
            }
            .padding(10)
            Divider().overlay(HubPalette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        let shown = label(item)
                        Button { pick(item) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(shown.title).font(.system(size: 12)).foregroundStyle(HubPalette.ink)
                                Text(shown.detail).font(.system(size: 11)).foregroundStyle(HubPalette.muted).lineLimit(1)
                                Spacer(minLength: 4)
                                if shown.current { Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(HubPalette.accent) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(shown.current ? HubPalette.accentSoft : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 280)
            if let note {
                Divider().overlay(HubPalette.line)
                Text(note).font(.system(size: 10)).foregroundStyle(HubPalette.muted).padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(width: 360)
        .background(HubPalette.panel)
    }
}

/// Children in a row that wraps to the next line when the room runs out, as
/// the proposal's bar does (`flex-wrap`); never wider than its column.
struct HubFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
