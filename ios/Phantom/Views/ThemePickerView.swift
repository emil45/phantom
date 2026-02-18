import SwiftUI

/// Sheet for selecting a terminal color theme.
struct ThemePickerView: View {
    let dataSource: TerminalDataSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(TerminalTheme.allThemes) { theme in
                Button {
                    dataSource.applyTheme(theme)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        // Color swatch
                        ZStack {
                            Circle()
                                .fill(Color(theme.background))
                                .frame(width: 32, height: 32)
                            Circle()
                                .fill(Color(theme.foreground))
                                .frame(width: 14, height: 14)
                        }
                        .overlay(
                            Circle()
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                .frame(width: 32, height: 32)
                        )

                        Text(theme.name)
                            .foregroundStyle(.primary)

                        Spacer()

                        if theme.id == dataSource.currentThemeId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
