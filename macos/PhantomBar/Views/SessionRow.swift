import SwiftUI

struct SessionRow: View {
    let session: SessionInfo
    let onDestroy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(session.shell.components(separatedBy: "/").last ?? session.shell)
                .lineLimit(1)

            Text(String(session.id.prefix(8)))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            if session.attached {
                Text("attached")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(3)
            }

            Spacer()

            if session.alive {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
            Divider()
            Button("Destroy Session", role: .destructive) {
                onDestroy()
            }
        }
    }
}
