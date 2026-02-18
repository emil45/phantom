import Foundation
import SwiftTerm
import UIKit

/// Wires SwiftTerm to the ReconnectManager for frame-based I/O.
/// Terminal output (Data/Scrollback frames) → feed to SwiftTerm.
/// User input from SwiftTerm → send as Data frames via ReconnectManager.
@MainActor
final class TerminalDataSource: NSObject, ObservableObject, TerminalViewDelegate {
    let terminalView: TerminalView
    weak var reconnectManager: ReconnectManager?
    @Published var currentThemeId: String

    init(reconnectManager: ReconnectManager) {
        let theme = TerminalTheme.saved
        self.currentThemeId = theme.id
        self.terminalView = TerminalView(frame: .zero)
        self.reconnectManager = reconnectManager
        super.init()

        terminalView.terminalDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        applyThemeColors(theme)

        // Wire incoming data frames to terminal
        reconnectManager.onTerminalData = { [weak self] data in
            let bytes = ArraySlice(data)
            self?.terminalView.feed(byteArray: bytes)
        }

        // Wire scrollback frames to terminal (on reattach)
        reconnectManager.onScrollbackData = { [weak self] data in
            let bytes = ArraySlice(data)
            self?.terminalView.feed(byteArray: bytes)
        }
    }

    // MARK: - TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let d = Data(data)
        Task { @MainActor in
            reconnectManager?.sendInput(d)
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            reconnectManager?.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
    }

    /// Apply a terminal color theme, persist selection, and update UI.
    func applyTheme(_ theme: TerminalTheme) {
        applyThemeColors(theme)
        TerminalTheme.save(theme)
        currentThemeId = theme.id
    }

    private func applyThemeColors(_ theme: TerminalTheme) {
        terminalView.nativeBackgroundColor = theme.background
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.caretColor = theme.cursor
        terminalView.selectedTextBackgroundColor = theme.selection
        if let ansi = theme.ansiColors {
            terminalView.installColors(ansi)
        }
        terminalView.overrideUserInterfaceStyle = theme.isDark ? .dark : .unspecified
    }

    /// Paste from system clipboard into terminal.
    func paste() {
        guard let string = UIPasteboard.general.string,
              let data = string.data(using: .utf8) else { return }
        reconnectManager?.sendInput(data)
    }

    /// Adjust terminal font size by delta points.
    func adjustFontSize(delta: CGFloat) {
        let current = terminalView.font.pointSize
        let newSize = max(8, min(32, current + delta))
        let font = UIFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        terminalView.font = font
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func bell(source: TerminalView) {}

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        }
    }
}
