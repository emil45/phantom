import SwiftUI
import SwiftTerm

/// UIViewRepresentable wrapping SwiftTerm's TerminalView.
/// Bridges SwiftUI lifecycle with the UIKit-based terminal emulator.
struct TerminalContainerView: UIViewRepresentable {
    let terminalView: TerminalView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),
        ])

        // Become first responder after a brief delay to ensure the view is in the hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            terminalView.becomeFirstResponder()
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // No dynamic updates needed — data is fed directly via TerminalDataSource.
    }
}
