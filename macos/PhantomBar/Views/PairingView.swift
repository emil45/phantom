import SwiftUI
import CoreImage.CIFilterBuiltins

struct PairingView: View {
    @EnvironmentObject var state: DaemonState
    @Environment(\.dismiss) var dismiss

    @State private var pairingInfo: PairingInfo?
    @State private var qrImage: NSImage?
    @State private var error: String?
    @State private var timeRemaining: Int = 300
    @State private var showManualEntry = false
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair New Device")
                .font(.headline)

            if let error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            } else if let info = pairingInfo {
                // QR Code (generated off main thread)
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
                    .foregroundColor(.secondary)

                // Countdown
                HStack {
                    Image(systemName: "clock")
                    Text("Expires in \(formattedTime)")
                }
                .font(.caption)
                .foregroundColor(timeRemaining < 60 ? .red : .secondary)

                // Manual entry
                DisclosureGroup("Manual Entry", isExpanded: $showManualEntry) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledField(label: "Host", value: "\(info.host):\(info.port)")
                        LabeledField(label: "Token", value: info.token)
                        LabeledField(label: "Fingerprint", value: info.fingerprint)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Generating pairing code...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 280)
        .task {
            await loadPairing()
        }
        .task(id: pairingInfo?.token) {
            guard let info = pairingInfo else { return }
            let payload = info.qrPayloadJson
            let image = await Task.detached(priority: .userInitiated) {
                Self.makeQRCode(from: payload)
            }.value
            qrImage = image
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

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
            startCountdown()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startCountdown() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                timer?.invalidate()
                pairingInfo = nil
                qrImage = nil
                error = "Pairing code expired. Close and try again."
            }
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
                .foregroundColor(.secondary)
                .font(.caption2)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
