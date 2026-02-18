import SwiftUI
import CodeScanner

/// Multi-step onboarding: Welcome -> QR Scanner -> Success.
/// Clean, focused, one action per screen.
struct PairingView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    @State private var step: OnboardingStep = .welcome
    @State private var showManualEntry = false
    @State private var errorMessage: String?
    @State private var pairedServerName: String?

    // Manual entry fields
    @State private var manualHost = ""
    @State private var manualPort = "4433"
    @State private var manualToken = ""
    @State private var manualFingerprint = ""

    private let colors = PhantomColors.defaultDark

    private enum OnboardingStep {
        case welcome
        case scanning
        case connecting
        case success
    }

    var body: some View {
        ZStack {
            colors.base.ignoresSafeArea()

            VStack(spacing: 0) {
                switch step {
                case .welcome:
                    welcomeStep
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                case .scanning:
                    scanningStep
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                case .connecting:
                    connectingStep
                        .transition(.opacity)
                case .success:
                    successStep
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .animation(.sessionSwitch, value: step)
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
        .onChange(of: reconnectManager.state) { newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: PhantomSpacing.lg) {
            Spacer()

            VStack(spacing: PhantomSpacing.md) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(colors.accent)

                Text("Phantom")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(colors.textPrimary)

                Text("Secure terminal access to your Mac")
                    .font(PhantomFont.body)
                    .foregroundStyle(colors.textSecondary)
            }

            Spacer()

            VStack(spacing: PhantomSpacing.md) {
                Button {
                    withAnimation(.sessionSwitch) { step = .scanning }
                } label: {
                    Text("Pair with Mac")
                        .font(PhantomFont.headline)
                        .foregroundStyle(colors.base)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PhantomSpacing.md)
                        .background(colors.accent, in: Capsule())
                }

                Text("Run `phantom pair` on your Mac first")
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(colors.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, PhantomSpacing.safe)
            .padding(.bottom, PhantomSpacing.xl)
        }
    }

    // MARK: - Scanning Step

    private var scanningStep: some View {
        VStack(spacing: 0) {
            // Scanner — fills most of the screen
            ZStack {
                CodeScannerView(
                    codeTypes: [.qr],
                    simulatedData: "{\"host\":\"127.0.0.1\",\"port\":4433,\"fp\":\"lJEsdZhFfnLYkFwqJJX+9BzNiQ8T2ZRVROKTVJOIlEA=\",\"tok\":\"p30AAk7atHE3utYLn6RZFD1x4o4Oui5iTg0eHxzToSg\",\"name\":\"Test Mac\",\"v\":1}",
                    completion: handleScan
                )

                // Viewfinder overlay
                RoundedRectangle(cornerRadius: PhantomRadius.card)
                    .stroke(colors.accent.opacity(0.5), lineWidth: 2)
                    .frame(width: 240, height: 240)
            }
            .frame(maxHeight: .infinity)
            .clipped()

            // Bottom panel
            VStack(spacing: PhantomSpacing.md) {
                Text("Scan the QR code from `phantom pair`")
                    .font(PhantomFont.body)
                    .foregroundStyle(colors.textPrimary)
                    .multilineTextAlignment(.center)

                if let error = errorMessage {
                    Text(error)
                        .font(PhantomFont.caption)
                        .foregroundStyle(colors.statusError)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Button {
                    showManualEntry = true
                } label: {
                    Text("Enter manually")
                        .font(PhantomFont.secondaryLabel)
                        .foregroundStyle(colors.textSecondary)
                }

                Button {
                    withAnimation(.sessionSwitch) { step = .welcome }
                } label: {
                    Text("Back")
                        .font(PhantomFont.secondaryLabel)
                        .foregroundStyle(colors.textSecondary.opacity(0.6))
                }
            }
            .padding(.vertical, PhantomSpacing.lg)
            .padding(.horizontal, PhantomSpacing.safe)
            .background(colors.surface)
        }
    }

    // MARK: - Connecting Step

    private var connectingStep: some View {
        VStack(spacing: PhantomSpacing.lg) {
            Spacer()

            VStack(spacing: PhantomSpacing.md) {
                ProgressView()
                    .tint(colors.accent)
                    .scaleEffect(1.2)

                Text("Connecting\u{2026}")
                    .font(PhantomFont.headline)
                    .foregroundStyle(colors.textPrimary)

                if let name = pairedServerName {
                    Text(name)
                        .font(PhantomFont.captionMono)
                        .foregroundStyle(colors.textSecondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Success Step

    private var successStep: some View {
        VStack(spacing: PhantomSpacing.lg) {
            Spacer()

            VStack(spacing: PhantomSpacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(colors.accent)

                Text("Connected")
                    .font(PhantomFont.title)
                    .foregroundStyle(colors.textPrimary)

                if let name = pairedServerName {
                    Text(name)
                        .font(PhantomFont.body)
                        .foregroundStyle(colors.textSecondary)
                }

                if let fp = reconnectManager.deviceStore.serverFingerprint {
                    Text(formatFingerprint(fp))
                        .font(PhantomFont.captionMono)
                        .foregroundStyle(colors.textSecondary.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, PhantomSpacing.xxs)
                }
            }

            Spacer()
        }
    }

    // MARK: - Manual Entry Sheet

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
                                .foregroundStyle(colors.statusError)
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
                        pairedServerName = manualHost
                        withAnimation(.sessionSwitch) { step = .connecting }
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

    // MARK: - Logic

    private func handleScan(result: Result<ScanResult, ScanError>) {
        switch result {
        case .success(let scan):
            guard let payload = PairingPayload.decode(from: scan.string) else {
                errorMessage = "Invalid QR code \u{2014} scan the code from phantom pair"
                return
            }
            errorMessage = nil
            pairedServerName = payload.serverName
            withAnimation(.sessionSwitch) { step = .connecting }
            reconnectManager.connectForPairing(
                host: payload.host,
                port: payload.port,
                fingerprint: payload.fingerprint,
                token: payload.token,
                serverName: payload.serverName
            )
        case .failure:
            errorMessage = "Camera failed \u{2014} try entering details manually"
        }
    }

    private func handleStateChange(_ newState: ConnectionState) {
        switch newState {
        case .connected:
            PhantomHaptic.pairingSuccess()
            withAnimation(.sessionSwitch) { step = .success }
            // Auto-dismiss after brief pause
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // The RootView will switch to terminal view when isPaired becomes true
            }
        case .disconnected:
            if step == .connecting {
                withAnimation(.sessionSwitch) { step = .scanning }
                errorMessage = "Connection failed \u{2014} check that phantom pair is running"
            }
        default:
            break
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

    private func formatFingerprint(_ fp: String) -> String {
        let upper = fp.prefix(24).uppercased()
        var result = ""
        for (i, char) in upper.enumerated() {
            if i > 0 && i % 4 == 0 { result += " " }
            result.append(char)
        }
        return result
    }
}
