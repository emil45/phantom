import SwiftUI
import Combine

@main
struct PhantomBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private let daemonState = DaemonState()
    private let setupManager = SetupManager()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = StatusPopover()
            .environmentObject(daemonState)
            .environmentObject(setupManager)

        statusBarController = StatusBarController(contentView: contentView)

        statusBarController.onPopoverOpen = { [weak self] in
            self?.daemonState.startPolling(fast: true)
        }
        statusBarController.onPopoverClose = { [weak self] in
            self?.daemonState.startPolling(fast: false)
        }

        // Update status bar icon when connected-device state changes
        daemonState.$snapshot
            .map { $0.devices.contains { $0.isConnected } }
            .removeDuplicates()
            .sink { [weak self] connected in
                self?.statusBarController.updateIcon(connected: connected)
            }
            .store(in: &cancellables)

        // One-time setup, then begin slow background polling for icon updates
        setupManager.ensureSetup()
        daemonState.startPolling(fast: false)
    }
}

// MARK: - Status Bar Controller

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var lastCloseTime = Date.distantPast

    var onPopoverOpen: (() -> Void)?
    var onPopoverClose: (() -> Void)?

    init<Content: View>(contentView: Content) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        super.init()

        let hosting = NSHostingController(rootView: contentView)
        hosting.sizingOptions = [.preferredContentSize]

        popover.contentSize = NSSize(width: 320, height: 300)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hosting

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "Phantom"
            )
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    func updateIcon(connected: Bool) {
        let name = connected ? "terminal.fill" : "terminal"
        statusItem.button?.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "Phantom"
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Prevent reopen when the transient close races with the button click
            guard Date().timeIntervalSince(lastCloseTime) > 0.2 else { return }
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        onPopoverOpen?()
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseTime = Date()
        onPopoverClose?()
    }
}
