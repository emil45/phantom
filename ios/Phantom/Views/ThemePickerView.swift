import SwiftUI
import SwiftTerm

/// Theme picker presented as a bottom sheet with card previews.
/// Each card shows a mini terminal preview with the theme's actual colors.
struct ThemePickerView: View {
    let dataSource: TerminalDataSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phantomColors) private var colors

    private let columns = [
        GridItem(.flexible(), spacing: PhantomSpacing.sm),
        GridItem(.flexible(), spacing: PhantomSpacing.sm),
        GridItem(.flexible(), spacing: PhantomSpacing.sm),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                // Font size controls
                fontSizeControls
                    .padding(.horizontal, PhantomSpacing.md)
                    .padding(.top, PhantomSpacing.sm)

                // Theme grid
                LazyVGrid(columns: columns, spacing: PhantomSpacing.sm) {
                    ForEach(TerminalTheme.allThemes) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: theme.id == dataSource.currentThemeId,
                            onSelect: {
                                dataSource.applyTheme(theme)
                            }
                        )
                    }
                }
                .padding(.horizontal, PhantomSpacing.md)
                .padding(.top, PhantomSpacing.sm)
                .padding(.bottom, PhantomSpacing.lg)
            }
            .background(colors.base)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(colors.accent)
                }
            }
        }
    }

    // MARK: - Font Size Controls

    private var fontSizeControls: some View {
        HStack(spacing: PhantomSpacing.sm) {
            Button {
                dataSource.adjustFontSize(delta: -1)
            } label: {
                Text("A")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PhantomSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: PhantomRadius.card)
                            .fill(colors.surface)
                    )
            }

            Button {
                dataSource.adjustFontSize(delta: 1)
            } label: {
                Text("A")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PhantomSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: PhantomRadius.card)
                            .fill(colors.surface)
                    )
            }
        }
    }
}

// MARK: - Theme Card

private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: PhantomSpacing.xs) {
                // Mini terminal preview
                terminalPreview
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: PhantomRadius.key))
                    .overlay(
                        RoundedRectangle(cornerRadius: PhantomRadius.key)
                            .stroke(
                                isSelected ? Color(theme.cursor) : Color.clear,
                                lineWidth: 2
                            )
                    )

                // Theme name
                Text(theme.name)
                    .font(PhantomFont.caption)
                    .foregroundStyle(isSelected ? Color(theme.cursor) : Color(hex: 0x8B95A5))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// Mini terminal preview showing simulated content lines.
    private var terminalPreview: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Color(theme.background)

            // Simulated terminal lines
            VStack(alignment: .leading, spacing: 3) {
                previewLine(ansiColor(2, fallback: theme.foreground), width: 0.7)
                previewLine(Color(theme.foreground), width: 0.5)
                previewLine(ansiColor(4, fallback: theme.cursor), width: 0.6)
                previewLine(Color(theme.foreground), width: 0.4)
                previewLine(ansiColor(3, fallback: theme.foreground), width: 0.55)
            }
            .padding(PhantomSpacing.xs)
        }
    }

    private func ansiColor(_ index: Int, fallback: UIColor) -> SwiftUI.Color {
        guard let ansi = theme.ansiColors, index < ansi.count else {
            return SwiftUI.Color(fallback)
        }
        return SwiftUI.Color(UIColor(swiftTermColor: ansi[index]))
    }

    private func previewLine(_ color: SwiftUI.Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color.opacity(0.8))
            .frame(height: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: width, y: 1, anchor: .leading)
    }
}

// MARK: - SwiftTerm.Color to UIColor

private extension UIColor {
    convenience init(swiftTermColor c: SwiftTerm.Color) {
        self.init(
            red: CGFloat(c.red) / 65535,
            green: CGFloat(c.green) / 65535,
            blue: CGFloat(c.blue) / 65535,
            alpha: 1
        )
    }
}
