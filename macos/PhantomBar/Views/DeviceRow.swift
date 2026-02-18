import SwiftUI

struct DeviceRow: View {
    let device: DeviceInfo
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(device.deviceName)
                .lineLimit(1)

            Spacer()

            if device.isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Device ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.deviceId, forType: .string)
            }
            Divider()
            Button("Revoke Device", role: .destructive) {
                onRevoke()
            }
        }
    }
}
