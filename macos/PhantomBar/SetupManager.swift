import Foundation
import ServiceManagement
import os

/// Handles first-launch setup: LaunchAgent installation, login item registration, daemon lifecycle.
/// Idempotent — safe to call `ensureSetup()` on every app launch.
@MainActor
class SetupManager: ObservableObject {
    @Published var setupError: String?

    private let label = "com.phantom.daemon"
    private let logger = Logger(subsystem: "com.phantom.bar", category: "SetupManager")

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.phantom.daemon.plist")
    }

    private var embeddedDaemonURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/phantom-daemon")
    }

    private var logDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".phantom/logs")
    }

    /// Run on every app launch. Installs/updates LaunchAgent, registers login item, starts daemon.
    func ensureSetup() {
        setupError = nil

        do {
            try installLaunchAgent()
            registerLoginItem()
            try startDaemon()
            logger.info("Setup complete")
        } catch {
            setupError = error.localizedDescription
            logger.error("Setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - LaunchAgent

    private func installLaunchAgent() throws {
        guard let daemonPath = embeddedDaemonURL?.path,
              FileManager.default.isExecutableFile(atPath: daemonPath) else {
            // No embedded daemon (dev build) — skip LaunchAgent install
            logger.info("No embedded daemon binary, skipping LaunchAgent install")
            return
        }

        // Ensure ~/Library/LaunchAgents exists
        let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        // Ensure log directory exists
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // Unload existing agent (ignore errors — may not be loaded)
        unloadLaunchAgent()

        let logPath = logDir.appendingPathComponent("daemon.log").path

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemonPath, "daemon"],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)
        logger.info("Wrote LaunchAgent plist to \(self.launchAgentURL.path)")
    }

    // MARK: - Login Item

    private func registerLoginItem() {
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do {
                try service.register()
                logger.info("Registered login item")
            } catch {
                // Non-fatal — user can still launch manually
                logger.warning("Failed to register login item: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Daemon Lifecycle

    func startDaemon() throws {
        let plistPath = launchAgentURL.path
        guard FileManager.default.fileExists(atPath: plistPath) else {
            // No plist — fall back to DaemonMonitor's direct launch
            logger.info("No LaunchAgent plist, skipping launchctl load")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            logger.warning("launchctl load exited with status \(process.terminationStatus)")
        }
    }

    func stopDaemon() throws {
        unloadLaunchAgent()
    }

    private func unloadLaunchAgent() {
        let plistPath = launchAgentURL.path
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistPath]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.warning("launchctl unload failed: \(error.localizedDescription)")
        }
    }
}
