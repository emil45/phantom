import SwiftUI
import CodeScanner

/// QR code scanner + manual pairing entry.
/// Shown when the device is not yet paired with a daemon.
struct PairingView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "4433"
    @State private var manualToken = ""
    @State private var manualFingerprint = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Phantom")
                .font(.largeTitle.bold())

            Text("Scan the QR code shown by\nphantom pair on your Mac")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // QR Scanner
            CodeScannerView(
                codeTypes: [.qr],
                simulatedData: "{\"host\":\"127.0.0.1\",\"port\":4433,\"fp\":\"test\",\"tok\":\"test-token\",\"name\":\"Test Mac\",\"v\":1}",
                completion: handleScan
            )
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button("Enter manually instead") {
                showManualEntry = true
            }
            .font(.subheadline)

            if reconnectManager.state == .connecting || reconnectManager.state == .authenticating {
                ProgressView("Pairing...")
            }
        }
        .padding()
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
    }

    private var manualEntrySheet: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host (IP or hostname)", text: $manualHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $manualPort)
                        .keyboardType(.numberPad)
                }
                Section("Pairing") {
                    TextField("Token", text: $manualToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Fingerprint (optional)", text: $manualFingerprint)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Manual Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showManualEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        showManualEntry = false
                        let port = UInt16(manualPort) ?? 4433
                        let fp = manualFingerprint.isEmpty ? nil : manualFingerprint
                        reconnectManager.connectForPairing(
                            host: manualHost,
                            port: port,
                            fingerprint: fp ?? "",
                            token: manualToken,
                            serverName: manualHost
                        )
                    }
                    .disabled(manualHost.isEmpty || manualToken.isEmpty)
                }
            }
        }
    }

    private func handleScan(result: Result<ScanResult, ScanError>) {
        switch result {
        case .success(let scan):
            guard let payload = PairingPayload.decode(from: scan.string) else {
                errorMessage = "Invalid QR code"
                return
            }
            errorMessage = nil
            reconnectManager.connectForPairing(
                host: payload.host,
                port: payload.port,
                fingerprint: payload.fingerprint,
                token: payload.token,
                serverName: payload.serverName
            )
        case .failure(let error):
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
    }
}
