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

            Text("Scan the QR code shown by\n**phantom pair** on your Mac")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // QR Scanner
            CodeScannerView(
                codeTypes: [.qr],
                simulatedData: "{\"host\":\"127.0.0.1\",\"port\":4433,\"fp\":\"lJEsdZhFfnLYkFwqJJX+9BzNiQ8T2ZRVROKTVJOIlEA=\",\"tok\":\"p30AAk7atHE3utYLn6RZFD1x4o4Oui5iTg0eHxzToSg\",\"name\":\"Test Mac\",\"v\":1}",
                completion: handleScan
            )
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            if reconnectManager.state == .connecting || reconnectManager.state == .authenticating {
                ProgressView("Connecting to server...")
            }

            Button("Enter manually instead") {
                showManualEntry = true
            }
            .font(.subheadline)
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
                    if let portError = portValidationError {
                        Text(portError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section("Pairing") {
                    TextField("Token", text: $manualToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Fingerprint (optional)", text: $manualFingerprint)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text("Run **phantom pair** on your Mac to get these values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            host: manualHost.trimmingCharacters(in: .whitespaces),
                            port: port,
                            fingerprint: fp ?? "",
                            token: manualToken.trimmingCharacters(in: .whitespaces),
                            serverName: manualHost
                        )
                    }
                    .disabled(!isManualFormValid)
                }
            }
        }
    }

    private var isManualFormValid: Bool {
        !manualHost.trimmingCharacters(in: .whitespaces).isEmpty
        && !manualToken.trimmingCharacters(in: .whitespaces).isEmpty
        && portValidationError == nil
    }

    private var portValidationError: String? {
        guard !manualPort.isEmpty else { return nil }
        guard let port = UInt16(manualPort), port > 0 else {
            return "Port must be 1–65535"
        }
        return nil
    }

    private func handleScan(result: Result<ScanResult, ScanError>) {
        switch result {
        case .success(let scan):
            guard let payload = PairingPayload.decode(from: scan.string) else {
                errorMessage = "Invalid QR code — make sure you're scanning the code from phantom pair"
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
        case .failure:
            errorMessage = "Camera scan failed — try entering details manually"
        }
    }
}
