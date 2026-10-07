import LampBoardCore
import SwiftUI

/// The Settings window's content (U3): the nine sections of `SettingsCatalog`
/// down the side, the chosen one on the right.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var fleet: RemoteFleet
    let lampMaster: LampMasterService

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.section).font(.title2.weight(.semibold))
                    if let current = SettingsCatalog.sections.first(where: { $0.title == model.section }), current.warns {
                        Label(current.title == "LampMaster"
                              ? "Sends parts of your conversations to Anthropic, with your own sign-in."
                              : "Sending and answering are off until you turn them on.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    pane
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCatalog.sections, id: \.title) { section in
                Button { model.section = section.title } label: {
                    HStack(spacing: 8) {
                        Circle().fill(tint(section)).frame(width: 8, height: 8)
                        Text(section.title).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(model.section == section.title ? Color.accentColor.opacity(0.22) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.section == section.title ? [.isSelected, .isButton] : .isButton)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 210)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var pane: some View {
        switch model.section {
        case "Panel": PanelPane(model: model)
        case "Clicks & keys": ClicksPane(model: model)
        case "Alerts": AlertsPane(model: model)
        case "Claude Code & Codex": AgentsPane(model: model)
        case "Acting from the panel": ActingPane(model: model)
        case "LampMaster": SettingsGroupBox(title: SettingsCatalog.section(of: .lampMaster).groups[0].title, warns: true) {
            LampMasterSettings(service: lampMaster)
        }
        case "Other Macs": OtherMacsPane(fleet: fleet)
        case "Privacy & data": PrivacyPane(model: model)
        default: AboutPane(model: model)
        }
    }

    private func tint(_ section: SettingsCatalog.Section) -> Color {
        switch section.title {
        case "Panel", "Clicks & keys": return .blue
        case "Alerts", "Acting from the panel": return .orange
        case "Claude Code & Codex": return .green
        case "LampMaster": return StatusPalette.lampMasterTint
        default: return .gray
        }
    }
}

/// A group of settings under its title, in a rounded box; orange-edged when what
/// is inside acts on the sessions or leaves the Mac.
struct SettingsGroupBox<Content: View>: View {
    let title: String
    var warns = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(warns ? Color.orange.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

/// One setting: its name and its control on a line, what it does under them.
/// The name and the line come from `SettingsCatalog`, and nowhere else.
struct SettingRow<Control: View>: View {
    let id: SettingsCatalog.ID
    @ViewBuilder let control: () -> Control

    var body: some View {
        let item = SettingsCatalog.item(id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.label)
                Spacer(minLength: 12)
                control()
            }
            if !item.help.isEmpty {
                Text(item.help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A setting that is a switch.
struct SettingToggle: View {
    let id: SettingsCatalog.ID
    let isOn: Bool
    var enabled = true
    let set: (Bool) -> Void

    var body: some View {
        SettingRow(id: id) {
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!enabled)
                .accessibilityLabel(SettingsCatalog.item(id).label)
        }
    }
}
