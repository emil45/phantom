import SwiftUI
import UIKit

/// A quick-key model representing a single toolbar key.
struct QuickKey: Identifiable {
    let id = UUID()
    let label: String
    /// Raw bytes sent to the PTY.
    let input: Data
    let isWide: Bool

    init(_ label: String, input: String, wide: Bool = false) {
        self.label = label
        self.input = Data(input.utf8)
        self.isWide = wide
    }

    init(_ label: String, bytes: [UInt8], wide: Bool = false) {
        self.label = label
        self.input = Data(bytes)
        self.isWide = wide
    }
}

// MARK: - Quick Key Toolbar

/// Horizontal scrolling row of quick-access terminal keys.
/// Fires on press (not release) with light haptic feedback.
struct QuickKeyToolbar: View {
    let onKeyPress: (Data) -> Void
    let onToggleExtended: () -> Void
    @Environment(\.phantomColors) private var colors

    static let defaultKeys: [QuickKey] = [
        .init("esc", bytes: [0x1B]),
        .init("tab", bytes: [0x09]),
        .init("ctrl", bytes: [], wide: true),
        .init("alt", bytes: []),
        .init("^C", bytes: [0x03]),
        .init("paste", bytes: [], wide: true),
        .init("|", input: "|"),
        .init("/", input: "/"),
        .init("~", input: "~"),
        .init("-", input: "-"),
        .init("?", input: "?"),
    ]

    @State private var ctrlActive = false
    @State private var altActive = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.separator)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                // Grid toggle button
                Button(action: onToggleExtended) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 44, height: 40)
                }
                .accessibilityLabel("Show extended keyboard")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PhantomSpacing.xs) {
                        ForEach(Self.defaultKeys) { key in
                            if key.label == "ctrl" {
                                ModifierKeyButton(
                                    label: key.label,
                                    isActive: $ctrlActive,
                                    isWide: key.isWide
                                )
                            } else if key.label == "alt" {
                                ModifierKeyButton(
                                    label: key.label,
                                    isActive: $altActive,
                                    isWide: key.isWide
                                )
                            } else if key.label == "paste" {
                                PasteKeyButton(onPress: onKeyPress)
                            } else {
                                QuickKeyButton(key: key) { data in
                                    if ctrlActive {
                                        // Convert to control character: letter & 0x1F
                                        if let byte = data.first, byte >= 0x40, byte <= 0x7E {
                                            onKeyPress(Data([byte & 0x1F]))
                                        } else {
                                            onKeyPress(data)
                                        }
                                        ctrlActive = false
                                    } else {
                                        onKeyPress(data)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, PhantomSpacing.xs)
                }
            }
            .padding(.vertical, PhantomSpacing.xs)
            .background(colors.surface)
        }
    }
}

// MARK: - Quick Key Button

/// Individual key button: fires on press, light haptic, monospace label.
struct QuickKeyButton: View {
    let key: QuickKey
    let onPress: (Data) -> Void

    @State private var isPressed = false
    @Environment(\.phantomColors) private var colors

    var body: some View {
        Text(key.label)
            .font(PhantomFont.keyLabel)
            .foregroundStyle(isPressed ? colors.accent : colors.textPrimary)
            .padding(.horizontal, key.isWide ? PhantomSpacing.md : PhantomSpacing.sm)
            .padding(.vertical, PhantomSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: PhantomRadius.key)
                    .fill(isPressed ? colors.accent.opacity(0.15) : colors.elevated)
            )
            .accessibilityLabel(accessibilityName(for: key.label))
            .accessibilityAddTraits(.isKeyboardKey)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        PhantomHaptic.keyPress()
                        onPress(key.input)
                    }
                    .onEnded { _ in
                        withAnimation(.subtle) { isPressed = false }
                    }
            )
    }

    private func accessibilityName(for label: String) -> String {
        switch label {
        case "esc": return "Escape"
        case "tab": return "Tab"
        case "^C": return "Control C, interrupt"
        case "|": return "Pipe"
        case "/": return "Slash"
        case "~": return "Tilde"
        case "-": return "Dash"
        case "?": return "Question mark"
        default: return label
        }
    }
}

// MARK: - Modifier Key Button

/// Toggle-style modifier key (ctrl, alt) — stays active until consumed.
struct ModifierKeyButton: View {
    let label: String
    @Binding var isActive: Bool
    let isWide: Bool

    @Environment(\.phantomColors) private var colors

    var body: some View {
        Text(label)
            .font(PhantomFont.keyLabel)
            .foregroundStyle(isActive ? colors.base : colors.textPrimary)
            .padding(.horizontal, isWide ? PhantomSpacing.md : PhantomSpacing.sm)
            .padding(.vertical, PhantomSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: PhantomRadius.key)
                    .fill(isActive ? colors.accent : colors.elevated)
            )
            .accessibilityLabel("\(label) modifier")
            .accessibilityValue(isActive ? "active" : "inactive")
            .accessibilityAddTraits(.isToggle)
            .onTapGesture {
                PhantomHaptic.modifierToggle()
                isActive.toggle()
            }
    }
}

// MARK: - Paste Key

/// Reads clipboard and sends as input.
struct PasteKeyButton: View {
    let onPress: (Data) -> Void

    @State private var isPressed = false
    @Environment(\.phantomColors) private var colors

    var body: some View {
        Text("paste")
            .font(PhantomFont.keyLabel)
            .foregroundStyle(isPressed ? colors.accent : colors.textPrimary)
            .padding(.horizontal, PhantomSpacing.md)
            .padding(.vertical, PhantomSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: PhantomRadius.key)
                    .fill(isPressed ? colors.accent.opacity(0.15) : colors.elevated)
            )
            .accessibilityLabel("Paste from clipboard")
            .accessibilityAddTraits(.isKeyboardKey)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        PhantomHaptic.keyPress()
                        if let string = UIPasteboard.general.string,
                           let data = string.data(using: .utf8) {
                            onPress(data)
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.subtle) { isPressed = false }
                    }
            )
    }
}
