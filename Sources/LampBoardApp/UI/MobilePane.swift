import AppKit
import CoreImage
import LampBoardCore
import LampBoardMacSource
import SwiftUI

/// Settings › iPhone & iPad (W5, §2.4, Q17): the paired devices and their
/// revocation, the QR code that pairs one more, and the switch that lets a
/// device open terminals and act — off until the person turns it on.
struct MobilePane: View {
    @ObservedObject var server: MobileServer

    var body: some View {
        SettingsGroupBox(title: SettingsCatalog.section(of: .mobileDevices).groups[0].title, warns: true) {
            SettingRow(id: .mobileDevices) { EmptyView() }
            if server.devices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            } else {
                ForEach(server.devices, id: \.id) { device in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))"
                                 + (device.lastSeenAt.map { " · seen \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(device.actionFingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { server.forget(device.id) }
                    }
                }
                Button("Forget all") {
                    if Alerts.confirm(title: "Forget every iPhone and iPad?",
                                      message: "None of them reaches this Mac again until it is paired anew.",
                                      confirmTitle: "Forget all") { server.forgetAll() }
                }
            }
            SettingRow(id: .mobilePair) {
                if server.invitation == nil {
                    Button("Show the code") { server.openPairing() }
                } else {
                    Button("Close") { server.closePairing() }
                }
            }
            if let invitation = server.invitation {
                PairingCode(invitation: invitation, deadline: server.pairingDeadline)
            }
            if let problem = server.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        }
        SettingsGroupBox(title: SettingsCatalog.section(of: .mobileTerminals).groups[1].title, warns: true) {
            SettingToggle(id: .mobileTerminals, isOn: server.settings.terminalsOn) { server.setTerminals($0) }
        }
    }
}

/// The QR code, what it says in words, and the time left.
private struct PairingCode: View {
    let invitation: MacPairingInvitation
    let deadline: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let image = QRImage.make(invitation.url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                    .accessibilityLabel("Pairing code")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan it with LampBoard on the iPhone or iPad.")
                Text("This Mac: \(MacHostKey.fingerprint(openSSH: invitation.hostKey))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Closes in \(max(0, Int(deadline.timeIntervalSince(context.date)))) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("You will be asked here to confirm the device before it is paired.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum QRImage {
    static func make(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
