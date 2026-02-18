import SwiftUI

/// Full settings surface: Appearance, Connection, Security, About.
/// Accessed from the sessions sheet via gear icon.
struct SettingsView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phantomColors) private var colors
    @State private var showUnpairConfirmation = false
    @State private var fingerprintCopied = false

    var body: some View {
        List {
            appearanceSection
            connectionSection
            securitySection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Unpair from \(serverName)?",
            isPresented: $showUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                reconnectManager.removeDeviceAndDisconnect()
            }
        } message: {
            Text("You\u{2019}ll need to scan a new QR code to reconnect.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            NavigationLink {
                ThemePickerView(dataSource: dataSource)
            } label: {
                HStack {
                    Label("Theme", systemImage: "paintpalette")
                    Spacer()
                    Text(dataSource.currentThemeId)
                        .font(PhantomFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("Font Size", systemImage: "textformat.size")
                Spacer()
                Text("\(Int(dataSource.terminalView.font.pointSize))pt")
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Stepper("", onIncrement: {
                    dataSource.adjustFontSize(delta: 1)
                }, onDecrement: {
                    dataSource.adjustFontSize(delta: -1)
                })
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent {
                Text(serverName)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Server", systemImage: "desktopcomputer")
            }

            LabeledContent {
                Text(serverAddress)
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Address", systemImage: "network")
            }

            // Fingerprint — tappable to copy
            Button {
                if let fp = reconnectManager.deviceStore.serverFingerprint {
                    UIPasteboard.general.string = fp
                    fingerprintCopied = true
                    PhantomHaptic.tick()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        fingerprintCopied = false
                    }
                }
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Certificate Fingerprint")
                            Text(formattedFingerprint)
                                .font(PhantomFont.captionMono)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    Spacer()
                    if fingerprintCopied {
                        Text("Copied")
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.accent)
                            .transition(.opacity)
                    }
                }
            }
            .tint(.primary)

            LabeledContent {
                HStack(spacing: PhantomSpacing.xxs) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(reconnectManager.state.statusLabel)
                        .font(PhantomFont.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label("Status", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section("Security") {
            LabeledContent {
                Text(String(reconnectManager.deviceStore.deviceId.prefix(8)))
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Device ID", systemImage: "iphone")
            }

            Button(role: .destructive) {
                showUnpairConfirmation = true
            } label: {
                Label("Unpair from \(serverName)", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Version", systemImage: "info.circle")
            }
        }
    }

    // MARK: - Computed Properties

    private var serverName: String {
        reconnectManager.deviceStore.serverName ?? "Mac"
    }

    private var serverAddress: String {
        let host = reconnectManager.deviceStore.serverHost ?? "unknown"
        let port = reconnectManager.deviceStore.serverPort
        return "\(host):\(port)"
    }

    private var formattedFingerprint: String {
        guard let fp = reconnectManager.deviceStore.serverFingerprint else { return "None" }
        // Group into 4-char chunks for readability
        let upper = fp.prefix(32).uppercased()
        var result = ""
        for (i, char) in upper.enumerated() {
            if i > 0 && i % 4 == 0 { result += " " }
            result.append(char)
        }
        return result.isEmpty ? fp : result
    }

    private var statusColor: Color {
        switch reconnectManager.state {
        case .connected: return colors.statusConnected
        case .disconnected: return colors.statusError
        default: return colors.statusWarning
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
