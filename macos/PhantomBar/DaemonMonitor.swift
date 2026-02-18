import Foundation

/// Checks daemon status and provides start/stop via launchctl or direct process.
struct DaemonMonitor {
    private let socketPath: String
    private let phantomBinary: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/.phantom/daemon.sock"
        // Try to find the phantom binary
        phantomBinary = DaemonMonitor.findPhantomBinary()
    }

    var isDaemonRunning: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    func startDaemon() throws {
        // Try launchctl first (if a plist exists)
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.phantom.daemon.plist").path

        if FileManager.default.fileExists(atPath: plistPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", plistPath]
            try process.run()
            process.waitUntilExit()
            return
        }

        // Fall back to running the binary directly
        guard let binary = phantomBinary else {
            throw DaemonError.binaryNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["daemon"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stopDaemon() throws {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.phantom.daemon.plist").path

        if FileManager.default.fileExists(atPath: plistPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistPath]
            try process.run()
            process.waitUntilExit()
            return
        }

        // Fall back to pkill
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "phantom daemon"]
        try process.run()
        process.waitUntilExit()
    }

    private static func findPhantomBinary() -> String? {
        let candidates = [
            "/usr/local/bin/phantom",
            "/opt/homebrew/bin/phantom",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin/phantom").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum DaemonError: LocalizedError {
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Could not find the phantom binary. Install it with: cargo install --path daemon/phantom-daemon"
        }
    }
}
