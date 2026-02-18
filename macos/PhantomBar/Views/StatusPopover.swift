import SwiftUI

struct StatusPopover: View {
    @EnvironmentObject var state: DaemonState
    @EnvironmentObject var setupManager: SetupManager
    @State private var showPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
            Divider()

            if case .stopped = state.status {
                stoppedSection
            } else if case .error(let msg) = state.status {
                errorSection(msg)
            } else {
                // Devices
                devicesSection
                Divider()

                // Sessions
                sessionsSection
                Divider()

                // Pair action
                MenuRow(icon: "plus.circle", label: "Pair New Device") {
                    showPairing = true
                }

                Divider()
            }

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

                switch state.status {
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

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch state.status {
        case .running: return .green
        case .connecting: return .yellow
        case .stopped, .error: return .red
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
                do {
                    try setupManager.startDaemon()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        state.poll()
                    }
                } catch {
                    state.startDaemon()
                }
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
                state.poll()
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
                Text("\(state.devices.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if state.devices.isEmpty {
                Text("No paired devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(state.devices) { device in
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
                Text("\(state.sessions.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if state.sessions.isEmpty {
                Text("No active sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(state.sessions) { session in
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
                if state.status.isRunning {
                    MenuRow(label: "Stop Daemon", font: .caption, color: .secondary) {
                        do {
                            try setupManager.stopDaemon()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                state.poll()
                            }
                        } catch {
                            state.stopDaemon()
                        }
                    }
                } else if case .stopped = state.status {
                    MenuRow(label: "Start Daemon", font: .caption, color: .secondary) {
                        do {
                            try setupManager.startDaemon()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                state.poll()
                            }
                        } catch {
                            state.startDaemon()
                        }
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
            isHovered = hovering
        }
    }
}
