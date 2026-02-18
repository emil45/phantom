import SwiftUI

/// Bottom sheet for managing sessions and accessing settings.
/// Presented from the terminal via the session pill.
struct SessionsSheet: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phantomColors) private var colors

    var body: some View {
        NavigationStack {
            List {
                // Server info
                serverSection

                // Sessions
                sessionsSection

                // New session
                newSessionSection
            }
            .scrollContentBackground(.hidden)
            .background(colors.base.opacity(0.5))
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(
                            reconnectManager: reconnectManager,
                            dataSource: dataSource
                        )
                        .environment(\.phantomColors, colors)
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(colors.textSecondary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(colors.accent)
                }
            }
            .onAppear {
                if reconnectManager.state.isUsable {
                    reconnectManager.listSessions()
                }
            }
            .refreshable {
                reconnectManager.listSessions()
            }
        }
    }

    // MARK: - Server Info

    private var serverSection: some View {
        Section {
            HStack(spacing: PhantomSpacing.sm) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(colors.accent)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reconnectManager.deviceStore.serverName ?? "Mac")
                        .font(PhantomFont.headline)
                    Text(serverAddress)
                        .font(PhantomFont.captionMono)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: PhantomSpacing.xxs) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(reconnectManager.state.statusLabel)
                        .font(PhantomFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, PhantomSpacing.xxs)
        }
    }

    // MARK: - Sessions List

    private var sessionsSection: some View {
        Section {
            if reconnectManager.sessions.isEmpty && reconnectManager.state.isUsable {
                emptyState
            } else {
                ForEach(reconnectManager.sessions) { session in
                    Button {
                        PhantomHaptic.sessionSwitch()
                        reconnectManager.detachSession()
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            reconnectManager.attachSession(session.id)
                        }
                    } label: {
                        sessionRow(session)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            reconnectManager.destroySession(session.id)
                        } label: {
                            Label("End", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Active Sessions")
                    .font(PhantomFont.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(reconnectManager.sessions.filter(\.alive).count)")
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(.secondary)
            }
            .textCase(nil)
        }
    }

    // MARK: - New Session

    private var newSessionSection: some View {
        Section {
            Button {
                reconnectManager.createSession(rows: 24, cols: 80)
                dismiss()
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(PhantomFont.headline)
                    .foregroundStyle(colors.accent)
            }
            .disabled(!reconnectManager.state.isUsable)
        }
    }

    // MARK: - Session Row

    private func sessionRow(_ session: SessionInfo) -> some View {
        HStack(spacing: PhantomSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 14))
                .foregroundStyle(session.alive ? colors.accent : colors.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: PhantomRadius.key)
                        .fill(session.alive ? colors.accent.opacity(0.12) : colors.elevated)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(session.shell.map { ($0 as NSString).lastPathComponent } ?? "shell")
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                Text(String(session.id.prefix(12)))
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: PhantomSpacing.xs) {
                if session.id == reconnectManager.activeSessionId {
                    Text("active")
                        .font(PhantomFont.caption)
                        .foregroundStyle(colors.accent)
                        .padding(.horizontal, PhantomSpacing.xs)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(colors.accent.opacity(0.12)))
                }
                Circle()
                    .fill(session.alive ? colors.accent : colors.textSecondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, PhantomSpacing.xxs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: PhantomSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(colors.textSecondary.opacity(0.4))
            Text("No active sessions")
                .font(PhantomFont.secondaryLabel)
                .foregroundStyle(.secondary)
            Text("Create one to get started")
                .font(PhantomFont.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PhantomSpacing.xl)
        .listRowBackground(Color.clear)
    }

    // MARK: - Computed

    private var serverAddress: String {
        let host = reconnectManager.deviceStore.serverHost ?? "unknown"
        let port = reconnectManager.deviceStore.serverPort
        return "\(host):\(port)"
    }

    private var statusColor: Color {
        switch reconnectManager.state {
        case .connected: return colors.statusConnected
        case .disconnected: return colors.statusError
        default: return colors.statusWarning
        }
    }
}
