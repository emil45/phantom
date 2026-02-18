import SwiftUI

/// Full-screen terminal view with connection status and toolbar.
struct TerminalScreen: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @State private var showControls = false
    @State private var showThemePicker = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalContainerView(terminalView: dataSource.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.keyboard)

            // Status pill + controls toggle
            HStack(spacing: 8) {
                if reconnectManager.state != .connected {
                    Text(reconnectManager.state.statusLabel)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.85))
                        .clipShape(Capsule())
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Button {
                    showControls.toggle()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)

            // Controls overlay
            if showControls {
                VStack(spacing: 0) {
                    Button {
                        dataSource.paste()
                        showControls = false
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    Divider()
                    Button {
                        dataSource.adjustFontSize(delta: 1)
                        showControls = false
                    } label: {
                        Label("Larger Text", systemImage: "textformat.size.larger")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    Divider()
                    Button {
                        dataSource.adjustFontSize(delta: -1)
                        showControls = false
                    } label: {
                        Label("Smaller Text", systemImage: "textformat.size.smaller")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    Divider()
                    Button {
                        showThemePicker = true
                        showControls = false
                    } label: {
                        Label("Theme", systemImage: "paintpalette")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(width: 200)
                .offset(x: -8, y: 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView(dataSource: dataSource)
        }
        .onTapGesture {
            if showControls { showControls = false }
        }
    }

    private var statusColor: Color {
        switch reconnectManager.state {
        case .connected:
            return .green
        case .reconnecting, .connecting, .authenticating, .backgrounded:
            return .yellow
        case .disconnected:
            return .red
        }
    }
}
