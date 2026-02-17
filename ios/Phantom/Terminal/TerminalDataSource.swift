import Foundation
import SwiftTerm
import UIKit

/// Wires SwiftTerm to the ReconnectManager for frame-based I/O.
/// Terminal output (Data/Scrollback frames) → feed to SwiftTerm.
/// User input from SwiftTerm → send as Data frames via ReconnectManager.
final class TerminalDataSource: NSObject, TerminalViewDelegate {
    let terminalView: TerminalView
    weak var reconnectManager: ReconnectManager?

    init(reconnectManager: ReconnectManager) {
        self.terminalView = TerminalView(frame: .zero)
        self.reconnectManager = reconnectManager
        super.init()

        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()

        // Wire incoming data frames to terminal
        reconnectManager.onTerminalData = { [weak self] data in
            DispatchQueue.main.async {
                let bytes = Array(data)
                self?.terminalView.feed(byteArray: bytes)
            }
        }

        // Wire scrollback frames to terminal (on reattach)
        reconnectManager.onScrollbackData = { [weak self] data in
            DispatchQueue.main.async {
                let bytes = Array(data)
                self?.terminalView.feed(byteArray: bytes)
            }
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let d = Data(data)
        Task { @MainActor in
            reconnectManager?.sendInput(d)
        }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            reconnectManager?.sendResize(cols: UInt16(newCols), rows: UInt16(newRows))
        }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }
}
