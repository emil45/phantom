import SwiftUI

struct StatusPopover: View {
    @EnvironmentObject var state: DaemonState
    @EnvironmentObject var setupManager: SetupManager
    @State private var showPairing = false

    private var status: ConnectionStatus { state.snapshot.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
            Divider()

            // Content — switches based on daemon state
            Group {
                switch status {
                case .stopped:
                    stoppedSection
                case .error(let msg):
                    errorSection(msg)
                default:
                    connectedContent
                }
            }
            .animation(.easeInOut(duration: 0.2), value: status)

            // Footer
            footerSection
        }
        .frame(width: 320)
        .sheet(isPresented: $showPairing) {
            PairingView()
                .environmentObject(state)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Phantom")
                    .font(.headline)

                statusText
            }

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.3), value: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .stopped:
            Text("Not running")
                .font(.caption)
                .foregroundColor(.secondary)
        case .connecting:
            Text("Connecting...")
                .font(.caption)
                .foregroundColor(.secondary)
        case .running(let uptime):
            Text("Running \(formatUptime(uptime))")
                .font(.caption)
                .foregroundColor(.secondary)
        case .error:
            Text("Error")
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    private var statusColor: Color {
        switch status {
        case .running: .green
        case .connecting: .yellow
        case .stopped, .error: .red
        }
    }

    // MARK: - Connected Content

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            devicesSection
            Divider()

            sessionsSection
            Divider()

            MenuRow(icon: "plus.circle", label: "Pair New Device") {
                showPairing = true
            }

            Divider()
        }
    }

    // MARK: - Stopped

    private var stoppedSection: some View {
        VStack(spacing: 12) {
            Text("The Phantom daemon is not running.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Daemon") {
                Task { await state.startDaemon() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
    }

    private func errorSection(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)

            Button("Retry") {
                state.refresh()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
    }

    // MARK: - Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DEVICES")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                Spacer()
                Text("\(state.snapshot.devices.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if state.snapshot.devices.isEmpty {
                Text("No paired devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(state.snapshot.devices) { device in
                    DeviceRow(device: device) {
                        state.revokeDevice(device.deviceId)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SESSIONS")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                Spacer()
                Text("\(state.snapshot.sessions.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if state.snapshot.sessions.isEmpty {
                Text("No active sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(state.snapshot.sessions) { session in
                    SessionRow(session: session) {
                        state.destroySession(session.id)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = setupManager.setupError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            HStack(spacing: 0) {
                if status.isRunning {
                    MenuRow(label: "Stop Daemon", font: .caption, color: .secondary) {
                        Task { await state.stopDaemon() }
                    }
                } else if case .stopped = status {
                    MenuRow(label: "Start Daemon", font: .caption, color: .secondary) {
                        Task { await state.startDaemon() }
                    }
                }

                Spacer()

                MenuRow(label: "Quit", font: .caption, color: .secondary) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatUptime(_ seconds: UInt64) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
    }
}

// MARK: - Hoverable Menu Row

/// A row that highlights on hover like a native NSMenu item.
private struct MenuRow: View {
    var icon: String?
    var label: String
    var font: Font = .body
    var color: Color = .primary
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon {
                    Image(systemName: icon)
                }
                Text(label)
                    .font(font)
                    .foregroundColor(isHovered ? .white : color)
            }
            .frame(maxWidth: icon != nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
