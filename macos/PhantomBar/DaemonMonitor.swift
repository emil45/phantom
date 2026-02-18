import Foundation

/// Checks daemon status and provides start/stop via launchctl or direct process.
struct DaemonMonitor {
    private let socketPath: String
    private let phantomBinary: String?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/.phantom/daemon.sock"
        phantomBinary = DaemonMonitor.findPhantomBinary()
    }

    var isDaemonRunning: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    func startDaemon() async throws {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.phantom.daemon.plist").path

        if FileManager.default.fileExists(atPath: plistPath) {
            try await runProcess("/bin/launchctl", arguments: ["load", plistPath])
            return
        }

        // Fall back to running the binary directly (fire-and-forget — daemon runs in background)
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

    func stopDaemon() async throws {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.phantom.daemon.plist").path

        if FileManager.default.fileExists(atPath: plistPath) {
            try await runProcess("/bin/launchctl", arguments: ["unload", plistPath])
            return
        }

        // Fall back to pkill
        try await runProcess("/usr/bin/pkill", arguments: ["-f", "phantom daemon"])
    }

    /// Run a process asynchronously without blocking the calling thread.
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

    private static func findPhantomBinary() -> String? {
        let bundlePath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/phantom-daemon").path

        let candidates = [
            bundlePath,
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
