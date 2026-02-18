import SwiftUI
import CodeScanner

/// QR code scanner + manual pairing entry.
/// Styled with Phantom design tokens for a dark, tool-like onboarding feel.
struct PairingView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "4433"
    @State private var manualToken = ""
    @State private var manualFingerprint = ""
    @State private var errorMessage: String?

    private let colors = PhantomColors.defaultDark

    var body: some View {
        ZStack {
            colors.base.ignoresSafeArea()

            VStack(spacing: PhantomSpacing.lg) {
                Spacer()

                // Logo area
                VStack(spacing: PhantomSpacing.sm) {
                    Image(systemName: "terminal")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(colors.accent)

                    Text("Phantom")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(colors.textPrimary)

                    Text("Scan the QR code shown by\n**phantom pair** on your Mac")
                        .font(PhantomFont.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(colors.textSecondary)
                }

                // QR Scanner
                CodeScannerView(
                    codeTypes: [.qr],
                    simulatedData: "{\"host\":\"127.0.0.1\",\"port\":4433,\"fp\":\"lJEsdZhFfnLYkFwqJJX+9BzNiQ8T2ZRVROKTVJOIlEA=\",\"tok\":\"p30AAk7atHE3utYLn6RZFD1x4o4Oui5iTg0eHxzToSg\",\"name\":\"Test Mac\",\"v\":1}",
                    completion: handleScan
                )
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: PhantomRadius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: PhantomRadius.card)
                        .stroke(colors.elevated, lineWidth: 1)
                )
                .padding(.horizontal, PhantomSpacing.lg)

                if let error = errorMessage {
                    Text(error)
                        .font(PhantomFont.caption)
                        .foregroundStyle(Color(hex: 0xBF616A))
                        .padding(.horizontal, PhantomSpacing.md)
                }

                if reconnectManager.state == .connecting || reconnectManager.state == .authenticating {
                    HStack(spacing: PhantomSpacing.xs) {
                        ProgressView()
                            .tint(colors.accent)
                        Text("Connecting...")
                            .font(PhantomFont.secondaryLabel)
                            .foregroundStyle(colors.textSecondary)
                    }
                }

                Spacer()

                // Manual entry button
                Button {
                    showManualEntry = true
                } label: {
                    Text("Enter manually instead")
                        .font(PhantomFont.secondaryLabel)
                        .foregroundStyle(colors.textSecondary)
                }
                .padding(.bottom, PhantomSpacing.lg)
            }
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
    }

    private var manualEntrySheet: some View {
        NavigationStack {
            ZStack {
                colors.base.ignoresSafeArea()

                Form {
                    Section("Server") {
                        TextField("Host (IP or hostname)", text: $manualHost)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Port", text: $manualPort)
                            .keyboardType(.numberPad)
                        if let portError = portValidationError {
                            Text(portError)
                                .font(PhantomFont.caption)
                                .foregroundStyle(Color(hex: 0xBF616A))
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
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.textSecondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Manual Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            return "Port must be 1\u{2013}65535"
        }
        return nil
    }

    private func handleScan(result: Result<ScanResult, ScanError>) {
        switch result {
        case .success(let scan):
            guard let payload = PairingPayload.decode(from: scan.string) else {
                errorMessage = "Invalid QR code \u{2014} make sure you\u{2019}re scanning the code from phantom pair"
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
            errorMessage = "Camera scan failed \u{2014} try entering details manually"
        }
    }
}
