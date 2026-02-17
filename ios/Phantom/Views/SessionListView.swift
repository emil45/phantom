import SwiftUI

/// Lists active sessions with create/destroy controls.
struct SessionListView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @State private var navigateToTerminal = false

    var body: some View {
        List {
            Section {
                ForEach(reconnectManager.sessions) { session in
                    Button {
                        reconnectManager.attachSession(session.id)
                        navigateToTerminal = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.shell ?? "shell")
                                    .font(.body.monospaced())
                                Text(session.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                if session.attached {
                                    Text("attached")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                                Circle()
                                    .fill(session.alive ? .green : .gray)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
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
                    Spacer()
                    Text(reconnectManager.state.statusLabel)
                        .font(.caption)
                        .foregroundStyle(
                            reconnectManager.state == .connected ? .green :
                            reconnectManager.state == .disconnected ? .red : .yellow
                        )
                }
            }
        }
        .navigationTitle(reconnectManager.deviceStore.serverName ?? "Phantom")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reconnectManager.createSession(rows: 24, cols: 80)
                    navigateToTerminal = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!reconnectManager.state.isUsable)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    reconnectManager.disconnect()
                    reconnectManager.deviceStore.clearPairing()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
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
            TerminalScreen(reconnectManager: reconnectManager, dataSource: dataSource)
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            reconnectManager.activeSessionId = nil
                            navigateToTerminal = false
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
        }
    }
}
