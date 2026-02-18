import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: DaemonState

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            AboutTab()
                .environmentObject(state)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 420, height: 260)
    }
}

// MARK: - General

private struct GeneralTab: View {
    var body: some View {
        Form {
            Toggle("Start at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {}
                }
            ))

            Section("Files") {
                LabeledContent("Config") {
                    HStack {
                        Text("~/.phantom/config.toml")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Reveal") {
                            let url = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".phantom")
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Logs") {
                    HStack {
                        Text("~/.phantom/logs/")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Open") {
                            let url = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".phantom/logs/daemon.log")
                            if FileManager.default.fileExists(atPath: url.path) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutTab: View {
    @EnvironmentObject var state: DaemonState

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2013}"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Phantom")
                .font(.title2.weight(.semibold))

            Text("Version \(appVersion)")
                .foregroundStyle(.secondary)

            if state.snapshot.status.isRunning {
                if !state.snapshot.version.isEmpty {
                    Text("Daemon \(state.snapshot.version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !state.snapshot.certFingerprint.isEmpty {
                    HStack(spacing: 4) {
                        let fp = state.snapshot.certFingerprint
                        Text(String(fp.prefix(16)) + "\u{2026}")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.quaternary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fp, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Copy certificate fingerprint")
                    }
                }
            }

            Spacer()

            Button("Report an Issue\u{2026}") {
                if let url = URL(string: "https://github.com/emil45/phantom/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
