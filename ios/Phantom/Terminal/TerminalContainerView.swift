import SwiftUI
import SwiftTerm

/// UIViewRepresentable wrapping SwiftTerm's TerminalView.
/// Bridges SwiftUI lifecycle with the UIKit-based terminal emulator.
/// Includes pinch-to-zoom for font size adjustment.
struct TerminalContainerView: UIViewRepresentable {
    let terminalView: TerminalView

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalView: terminalView)
    }

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

        // Pinch-to-zoom gesture for font size
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        container.addGestureRecognizer(pinch)

        // Become first responder after a brief delay to ensure the view is in the hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            terminalView.becomeFirstResponder()
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // No dynamic updates needed — data is fed directly via TerminalDataSource.
    }

    // MARK: - Coordinator

    class Coordinator {
        let terminalView: TerminalView
        private var lastScale: CGFloat = 1.0

        init(terminalView: TerminalView) {
            self.terminalView = terminalView
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                lastScale = 1.0
            case .changed:
                let delta = gesture.scale - lastScale
                // Only trigger font change at meaningful thresholds
                if abs(delta) > 0.08 {
                    let direction: CGFloat = delta > 0 ? 1 : -1
                    let current = terminalView.font.pointSize
                    let newSize = max(8, min(32, current + direction))
                    if newSize != current {
                        terminalView.font = UIFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
                        PhantomHaptic.tick()
                    }
                    lastScale = gesture.scale
                }
            default:
                break
            }
        }
    }
}
