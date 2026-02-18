import SwiftUI
import UIKit

/// Key group categories for the extended panel.
/// Shows one group at a time instead of all 48+ keys simultaneously.
enum KeyGroup: String, CaseIterable, Identifiable {
    case control = "Ctrl"
    case navigation = "Nav"
    case brackets = "Brackets"
    case symbols = "Symbols"
    case function = "Fn"

    var id: String { rawValue }
}

/// Extended key panel with segmented group picker.
/// Reduces cognitive load by showing one category at a time.
struct ExtendedKeyPanel: View {
    let onKeyPress: (Data) -> Void
    let onDismiss: () -> Void
    let onShowThemePicker: () -> Void
    @Environment(\.phantomColors) private var colors
    @State private var selectedGroup: KeyGroup = .control

    // MARK: - Key Definitions

    private static let controlKeys: [QuickKey] = [
        .init("^C", bytes: [0x03]),
        .init("^D", bytes: [0x04]),
        .init("^Z", bytes: [0x1A]),
        .init("^\\", bytes: [0x1C]),
        .init("^L", bytes: [0x0C]),
        .init("^A", bytes: [0x01]),
        .init("^E", bytes: [0x05]),
        .init("^R", bytes: [0x12]),
    ]

    private static let navKeys: [QuickKey] = [
        .init("\u{2191}", bytes: [0x1B, 0x5B, 0x41]),  // Up
        .init("\u{2193}", bytes: [0x1B, 0x5B, 0x42]),  // Down
        .init("\u{2190}", bytes: [0x1B, 0x5B, 0x44]),  // Left
        .init("\u{2192}", bytes: [0x1B, 0x5B, 0x43]),  // Right
        .init("home", bytes: [0x1B, 0x5B, 0x48], wide: true),
        .init("end", bytes: [0x1B, 0x5B, 0x46], wide: true),
        .init("pgUp", bytes: [0x1B, 0x5B, 0x35, 0x7E], wide: true),
        .init("pgDn", bytes: [0x1B, 0x5B, 0x36, 0x7E], wide: true),
        .init("del", bytes: [0x1B, 0x5B, 0x33, 0x7E]),
        .init("ins", bytes: [0x1B, 0x5B, 0x32, 0x7E]),
    ]

    private static let bracketKeys: [QuickKey] = [
        .init("{", input: "{"),
        .init("}", input: "}"),
        .init("[", input: "["),
        .init("]", input: "]"),
        .init("(", input: "("),
        .init(")", input: ")"),
        .init("<", input: "<"),
        .init(">", input: ">"),
    ]

    private static let symbolKeys: [QuickKey] = [
        .init("$", input: "$"),
        .init("&", input: "&"),
        .init("*", input: "*"),
        .init("#", input: "#"),
        .init("@", input: "@"),
        .init("!", input: "!"),
        .init("=", input: "="),
        .init("%", input: "%"),
        .init("+", input: "+"),
        .init("_", input: "_"),
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
        .init("F9", bytes: [0x1B, 0x5B, 0x32, 0x30, 0x7E]),
        .init("F10", bytes: [0x1B, 0x5B, 0x32, 0x31, 0x7E]),
        .init("F11", bytes: [0x1B, 0x5B, 0x32, 0x33, 0x7E]),
        .init("F12", bytes: [0x1B, 0x5B, 0x32, 0x34, 0x7E]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.separator)
                .frame(height: 0.5)

            VStack(spacing: PhantomSpacing.sm) {
                // Segmented group picker
                groupPicker

                // Keys for selected group
                keyGrid(for: selectedGroup)
                    .animation(.stateChange, value: selectedGroup)
            }
            .padding(.horizontal, PhantomSpacing.sm)
            .padding(.vertical, PhantomSpacing.sm)
            .background(colors.surface)

            // Bottom action bar
            actionBar
        }
    }

    // MARK: - Group Picker

    private var groupPicker: some View {
        HStack(spacing: PhantomSpacing.xxs) {
            ForEach(KeyGroup.allCases) { group in
                Button {
                    PhantomHaptic.tick()
                    selectedGroup = group
                } label: {
                    Text(group.rawValue)
                        .font(PhantomFont.captionMono)
                        .foregroundStyle(
                            selectedGroup == group ? colors.accent : colors.textSecondary
                        )
                        .padding(.horizontal, PhantomSpacing.sm)
                        .padding(.vertical, PhantomSpacing.xxs + 2)
                        .background(
                            Capsule()
                                .fill(selectedGroup == group ? colors.accent.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Key Grid

    @ViewBuilder
    private func keyGrid(for group: KeyGroup) -> some View {
        let keys: [QuickKey] = {
            switch group {
            case .control: return Self.controlKeys
            case .navigation: return Self.navKeys
            case .brackets: return Self.bracketKeys
            case .symbols: return Self.symbolKeys
            case .function: return Self.functionKeys
            }
        }()

        // Wrap keys into rows of 8
        let rows = stride(from: 0, to: keys.count, by: 8).map { start in
            Array(keys[start..<min(start + 8, keys.count)])
        }

        VStack(spacing: PhantomSpacing.xxs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: PhantomSpacing.xxs) {
                    ForEach(row) { key in
                        QuickKeyButton(key: key, onPress: onKeyPress)
                    }
                }
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            actionButton(icon: "square.grid.2x2.fill", isActive: true) { onDismiss() }
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
}
