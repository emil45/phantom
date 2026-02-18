import SwiftUI
import CoreImage.CIFilterBuiltins

struct PairingView: View {
    @EnvironmentObject var state: DaemonState

    @State private var pairingInfo: PairingInfo?
    @State private var qrImage: NSImage?
    @State private var error: String?
    @State private var timeRemaining: Int = 300
    @State private var isExpired = false

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                errorContent(error)
            } else if let info = pairingInfo {
                qrContent(info)
            } else {
                loadingContent
            }
        }
        .padding(24)
        .frame(width: 320)
        .task {
            await loadPairing()
        }
        .task(id: pairingInfo?.token) {
            guard let info = pairingInfo else { return }

            // Generate QR code off main thread
            let payload = info.qrPayloadJson
            let image = await Task.detached(priority: .userInitiated) {
                Self.makeQRCode(from: payload)
            }.value
            qrImage = image

            // Countdown
            while timeRemaining > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                timeRemaining -= 1
            }
            if timeRemaining <= 0 && !Task.isCancelled {
                isExpired = true
                pairingInfo = nil
                qrImage = nil
                error = "Pairing code expired."
            }
        }
    }

    // MARK: - Content States

    @ViewBuilder
    private func qrContent(_ info: PairingInfo) -> some View {
        if let qrImage {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .frame(width: 200, height: 200)
        } else {
            ProgressView()
                .frame(width: 200, height: 200)
        }

        Text("Scan with the Phantom iOS app")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        HStack(spacing: 4) {
            Image(systemName: "clock")
            Text("Expires in \(formattedTime)")
        }
        .font(.caption)
        .foregroundStyle(timeRemaining < 60 ? .red : .secondary)

        DisclosureGroup("Manual Entry") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledField(label: "Host", value: "\(info.host):\(info.port)")
                LabeledField(label: "Token", value: info.token)
                LabeledField(label: "Fingerprint", value: info.fingerprint)
            }
            .padding(.top, 4)
        }
        .font(.caption)

        doneButton
    }

    @ViewBuilder
    private func errorContent(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.secondary)

        Text(message)
            .foregroundStyle(.red)
            .font(.caption)
            .multilineTextAlignment(.center)

        if isExpired {
            Button("Generate New Code") {
                isExpired = false
                error = nil
                Task { await loadPairing() }
            }
            .controlSize(.small)
        }

        doneButton
    }

    private var loadingContent: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Generating pairing code\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var doneButton: some View {
        Button("Done") {
            NSApp.keyWindow?.close()
        }
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Helpers

    private var formattedTime: String {
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadPairing() async {
        do {
            let info = try await state.createPairing()
            pairingInfo = info
            timeRemaining = Int(info.expiresInSecs)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func makeQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        let scale = 10.0
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

private struct LabeledField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption2)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
