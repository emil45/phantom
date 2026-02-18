import SwiftUI

/// Lists active sessions with create/destroy controls.
/// Styled with design tokens: session rows as subtle cards on dark background.
struct SessionListView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @State private var navigateToTerminal = false
    @Environment(\.phantomColors) private var colors

    var body: some View {
        ZStack {
            colors.base.ignoresSafeArea()

            List {
                Section {
                    ForEach(reconnectManager.sessions) { session in
                        Button {
                            reconnectManager.attachSession(session.id)
                            navigateToTerminal = true
                        } label: {
                            sessionRow(session)
                        }
                        .listRowBackground(colors.surface)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                reconnectManager.destroySession(session.id)
                            } label: {
                                Label("Destroy", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Sessions")
                            .font(PhantomFont.sectionHeader)
                            .foregroundStyle(colors.textSecondary)
                        Spacer()
                        connectionBadge
                    }
                    .textCase(nil)
                }

                if reconnectManager.sessions.isEmpty && reconnectManager.state.isUsable {
                    Section {
                        VStack(spacing: PhantomSpacing.sm) {
                            Image(systemName: "terminal")
                                .font(.system(size: 32))
                                .foregroundStyle(colors.textSecondary.opacity(0.5))
                            Text("No active sessions")
                                .font(PhantomFont.secondaryLabel)
                                .foregroundStyle(colors.textSecondary)
                            Text("Tap + to create one")
                                .font(PhantomFont.caption)
                                .foregroundStyle(colors.textSecondary.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PhantomSpacing.xl)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(reconnectManager.deviceStore.serverName ?? "Phantom")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reconnectManager.createSession(rows: 24, cols: 80)
                    navigateToTerminal = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(colors.accent)
                }
                .disabled(!reconnectManager.state.isUsable)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    reconnectManager.removeDeviceAndDisconnect()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(colors.textSecondary)
                }
            }
        }
        .refreshable {
            reconnectManager.listSessions()
        }
        .onAppear {
            if reconnectManager.state.isUsable {
                reconnectManager.listSessions()
            }
        }
        .navigationDestination(isPresented: $navigateToTerminal) {
            TerminalScreen(
                reconnectManager: reconnectManager,
                dataSource: dataSource,
                onDetach: { navigateToTerminal = false }
            )
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.phantomColors, PhantomColors(from: TerminalTheme.saved))
        }
    }

    // MARK: - Session Row

    private func sessionRow(_ session: SessionInfo) -> some View {
        HStack(spacing: PhantomSpacing.sm) {
            // Shell icon
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
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                Text(session.id.prefix(12).description)
                    .font(PhantomFont.caption)
                    .foregroundStyle(colors.textSecondary)
            }

            Spacer()

            HStack(spacing: PhantomSpacing.xs) {
                if session.attached {
                    Text("attached")
                        .font(PhantomFont.caption)
                        .foregroundStyle(colors.accent)
                        .padding(.horizontal, PhantomSpacing.xs)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(colors.accent.opacity(0.12))
                        )
                }
                Circle()
                    .fill(session.alive ? colors.accent : colors.textSecondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, PhantomSpacing.xxs)
    }

    // MARK: - Connection Badge

    private var connectionBadge: some View {
        HStack(spacing: PhantomSpacing.xxs) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(reconnectManager.state.statusLabel)
                .font(PhantomFont.caption)
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch reconnectManager.state {
        case .connected: return colors.accent
        case .disconnected: return Color(hex: 0xBF616A)
        default: return Color(hex: 0xEBCB8B)
        }
    }
}
