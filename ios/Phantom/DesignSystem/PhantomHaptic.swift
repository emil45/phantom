import UIKit

/// Centralized haptic vocabulary for consistent tactile feedback.
/// Each function maps to a specific user interaction — never reuse haptic styles
/// across semantically different actions.
enum PhantomHaptic {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Prepare all generators (call on scene activation).
    static func prepare() {
        lightImpact.prepare()
        mediumImpact.prepare()
        selection.prepare()
        notification.prepare()
    }

    /// Toolbar key press — light, subtle.
    static func keyPress() {
        lightImpact.impactOccurred(intensity: 0.5)
    }

    /// Modifier key toggle (ctrl, alt) — slightly stronger.
    static func modifierToggle() {
        mediumImpact.impactOccurred(intensity: 0.6)
    }

    /// Session tab switch, list selection.
    static func sessionSwitch() {
        selection.selectionChanged()
    }

    /// Connection established — success notification.
    static func connected() {
        notification.notificationOccurred(.success)
    }

    /// Connection lost — warning notification.
    static func disconnected() {
        notification.notificationOccurred(.warning)
    }

    /// Error state — error notification.
    static func error() {
        notification.notificationOccurred(.error)
    }

    /// Pairing success — two-tap pattern like Apple Pay.
    static func pairingSuccess() {
        mediumImpact.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            mediumImpact.impactOccurred(intensity: 0.7)
        }
    }

    /// Gentle tap for UI affordance discovery (long press, swipe threshold).
    static func tick() {
        lightImpact.impactOccurred(intensity: 0.3)
    }
}
