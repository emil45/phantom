import SwiftUI
import SwiftTerm

/// UIViewRepresentable wrapping SwiftTerm's TerminalView.
/// Bridges SwiftUI lifecycle with the UIKit-based terminal emulator.
struct TerminalContainerView: UIViewRepresentable {
    let terminalView: TerminalView

    func makeUIView(context: Context) -> TerminalView {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        return terminalView
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // No dynamic updates needed — data is fed directly via TerminalDataSource.
    }
}
