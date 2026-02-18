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

        Task {
            do {
                try await installLaunchAgent()
                registerLoginItem()
                try await loadAgent()
                logger.info("Setup complete")
            } catch {
                setupError = error.localizedDescription
                logger.error("Setup failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - LaunchAgent

    private func installLaunchAgent() async throws {
        guard let daemonPath = embeddedDaemonURL?.path,
              FileManager.default.isExecutableFile(atPath: daemonPath) else {
            logger.info("No embedded daemon binary, skipping LaunchAgent install")
            return
        }

        let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // Unload existing agent (ignore errors — may not be loaded)
        await unloadAgent()

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
                logger.warning("Failed to register login item: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Daemon Lifecycle

    private func loadAgent() async throws {
        let plistPath = launchAgentURL.path
        guard FileManager.default.fileExists(atPath: plistPath) else {
            logger.info("No LaunchAgent plist, skipping launchctl load")
            return
        }

        try await runProcess("/bin/launchctl", arguments: ["load", plistPath])
    }

    private func unloadAgent() async {
        let plistPath = launchAgentURL.path
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        do {
            try await runProcess("/bin/launchctl", arguments: ["unload", plistPath])
        } catch {
            logger.warning("launchctl unload failed: \(error.localizedDescription)")
        }
    }

    /// Run a process asynchronously without blocking the main thread.
    private func runProcess(_ path: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
