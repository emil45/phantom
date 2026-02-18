import SwiftUI
import UIKit

/// Full extended key panel with control characters, arrows, navigation, symbols, and function keys.
/// Organized in logical rows matching professional terminal app layouts.
struct ExtendedKeyPanel: View {
    let onKeyPress: (Data) -> Void
    let onDismiss: () -> Void
    let onShowThemePicker: () -> Void
    @Environment(\.phantomColors) private var colors

    // MARK: - Key Definitions

    private static let row1: [QuickKey] = [
        .init("^C", bytes: [0x03]),
        .init("^D", bytes: [0x04]),
        .init("^Z", bytes: [0x1A]),
        .init("^\\", bytes: [0x1C]),
        .init("^L", bytes: [0x0C]),
        .init("^A", bytes: [0x01]),
        .init("^E", bytes: [0x05]),
        .init("^R", bytes: [0x12]),
    ]

    private static let row2: [QuickKey] = [
        .init("\u{2191}", bytes: [0x1B, 0x5B, 0x41]),  // Up
        .init("\u{2193}", bytes: [0x1B, 0x5B, 0x42]),  // Down
        .init("\u{2190}", bytes: [0x1B, 0x5B, 0x44]),  // Left
        .init("\u{2192}", bytes: [0x1B, 0x5B, 0x43]),  // Right
        .init("home", bytes: [0x1B, 0x5B, 0x48], wide: true),
        .init("end", bytes: [0x1B, 0x5B, 0x46], wide: true),
    ]

    private static let row3: [QuickKey] = [
        .init("pgUp", bytes: [0x1B, 0x5B, 0x35, 0x7E], wide: true),
        .init("pgDn", bytes: [0x1B, 0x5B, 0x36, 0x7E], wide: true),
        .init("del", bytes: [0x1B, 0x5B, 0x33, 0x7E]),
        .init("ins", bytes: [0x1B, 0x5B, 0x32, 0x7E]),
        .init("paste", bytes: [], wide: true),
    ]

    private static let row4: [QuickKey] = [
        .init("{", input: "{"),
        .init("}", input: "}"),
        .init("[", input: "["),
        .init("]", input: "]"),
        .init("(", input: "("),
        .init(")", input: ")"),
        .init("<", input: "<"),
        .init(">", input: ">"),
    ]

    private static let row5: [QuickKey] = [
        .init("$", input: "$"),
        .init("&", input: "&"),
        .init("*", input: "*"),
        .init("#", input: "#"),
        .init("@", input: "@"),
        .init("!", input: "!"),
        .init("=", input: "="),
        .init("%", input: "%"),
    ]

    private static let functionKeys: [QuickKey] = [
        .init("F1", bytes: [0x1B, 0x4F, 0x50]),
        .init("F2", bytes: [0x1B, 0x4F, 0x51]),
        .init("F3", bytes: [0x1B, 0x4F, 0x52]),
        .init("F4", bytes: [0x1B, 0x4F, 0x53]),
        .init("F5", bytes: [0x1B, 0x5B, 0x31, 0x35, 0x7E]),
        .init("F6", bytes: [0x1B, 0x5B, 0x31, 0x37, 0x7E]),
        .init("F7", bytes: [0x1B, 0x5B, 0x31, 0x38, 0x7E]),
        .init("F8", bytes: [0x1B, 0x5B, 0x31, 0x39, 0x7E]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.separator)
                .frame(height: 0.5)

            VStack(spacing: PhantomSpacing.xs) {
                keyRow(Self.row1)
                keyRow(Self.row2)
                keyRow(Self.row3)
                keyRow(Self.row4)
                keyRow(Self.row5)
                keyRow(Self.functionKeys)
            }
            .padding(.horizontal, PhantomSpacing.sm)
            .padding(.vertical, PhantomSpacing.sm)
            .background(colors.surface)

            // Bottom action bar
            actionBar
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton(icon: "square.grid.2x2.fill", isActive: true) { onDismiss() }
            actionButton(icon: "curlybraces") { }
            actionButton(icon: "paintpalette") { onShowThemePicker() }
            actionButton(icon: "keyboard") { onDismiss() }
        }
        .padding(.vertical, PhantomSpacing.xs)
        .background(colors.surface)
    }

    private func actionButton(icon: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(isActive ? colors.accent : colors.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
    }

    @ViewBuilder
    private func keyRow(_ keys: [QuickKey]) -> some View {
        HStack(spacing: PhantomSpacing.xxs) {
            ForEach(keys) { key in
                if key.label == "paste" {
                    PasteKeyButton(onPress: onKeyPress)
                } else {
                    QuickKeyButton(key: key, onPress: onKeyPress)
                }
            }
        }
    }
}

// MARK: - Paste Key (reads clipboard)

private struct PasteKeyButton: View {
    let onPress: (Data) -> Void

    @State private var isPressed = false
    @Environment(\.phantomColors) private var colors
    private let haptic = UIImpactFeedbackGenerator(style: .light)

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
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        haptic.impactOccurred()
                        if let string = UIPasteboard.general.string,
                           let data = string.data(using: .utf8) {
                            onPress(data)
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.subtle) { isPressed = false }
                    }
            )
            .onAppear { haptic.prepare() }
    }
}
