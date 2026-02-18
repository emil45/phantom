import SwiftUI
import SwiftTerm

/// Theme picker with real terminal content previews and font size controls.
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
                VStack(spacing: PhantomSpacing.lg) {
                    fontSizeControls
                    themeGrid
                }
                .padding(.horizontal, PhantomSpacing.md)
                .padding(.vertical, PhantomSpacing.sm)
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

            // Current size display
            Text("\(Int(dataSource.terminalView.font.pointSize))pt")
                .font(PhantomFont.captionMono)
                .foregroundStyle(colors.textSecondary)
                .frame(width: 44)

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

    // MARK: - Theme Grid

    private var themeGrid: some View {
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
                // Mini terminal with real-looking content
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

                Text(theme.name)
                    .font(PhantomFont.caption)
                    .foregroundStyle(isSelected ? Color(theme.cursor) : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// Real terminal content preview using theme colors.
    private var terminalPreview: some View {
        ZStack(alignment: .topLeading) {
            Color(theme.background)

            VStack(alignment: .leading, spacing: 2) {
                // Simulated terminal lines with real-looking content
                previewLine {
                    Text("$ ")
                        .foregroundColor(ansiColor(2))
                    + Text("ls -la")
                        .foregroundColor(Color(theme.foreground))
                }
                previewLine {
                    Text("drwxr-xr-x ")
                        .foregroundColor(Color(theme.foreground).opacity(0.7))
                    + Text("src/")
                        .foregroundColor(ansiColor(4))
                }
                previewLine {
                    Text("-rw-r--r-- ")
                        .foregroundColor(Color(theme.foreground).opacity(0.7))
                    + Text("main.rs")
                        .foregroundColor(Color(theme.foreground))
                }
                previewLine {
                    Text("$ ")
                        .foregroundColor(ansiColor(2))
                    + Text("git status")
                        .foregroundColor(Color(theme.foreground))
                }
                previewLine {
                    Text("On branch ")
                        .foregroundColor(Color(theme.foreground).opacity(0.7))
                    + Text("main")
                        .foregroundColor(ansiColor(3))
                }
            }
            .padding(PhantomSpacing.xs)
        }
    }

    private func previewLine<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .font(.system(size: 6.5, design: .monospaced))
            .lineLimit(1)
    }

    private func ansiColor(_ index: Int) -> SwiftUI.Color {
        guard let ansi = theme.ansiColors, index < ansi.count else {
            return SwiftUI.Color(theme.foreground)
        }
        return SwiftUI.Color(UIColor(swiftTermColor: ansi[index]))
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
