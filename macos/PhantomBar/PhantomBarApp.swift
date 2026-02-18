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
        statusBarController = StatusBarController(
            daemonState: daemonState,
            setupManager: setupManager
        )

        daemonState.$snapshot
            .map { $0.status.isRunning }
            .removeDuplicates()
            .sink { [weak self] running in
                self?.statusBarController.updateIcon(daemonRunning: running)
            }
            .store(in: &cancellables)

        daemonState.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                self?.statusBarController.updateAccessibility(snapshot: snapshot)
            }
            .store(in: &cancellables)

        setupManager.ensureSetup()
        daemonState.startPolling(fast: false)
    }
}

// MARK: - Status Bar Controller

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let daemonState: DaemonState
    private let setupManager: SetupManager
    private var pairingPanel: NSPanel?
    private var settingsWindow: NSWindow?

    init(daemonState: DaemonState, setupManager: SetupManager) {
        self.daemonState = daemonState
        self.setupManager = setupManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()

        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "lock.shield",
                accessibilityDescription: "Phantom"
            )
            image?.isTemplate = true
            button.image = image
        }
    }

    func updateIcon(daemonRunning: Bool) {
        statusItem.button?.appearsDisabled = !daemonRunning
    }

    func updateAccessibility(snapshot: DaemonSnapshot) {
        let connected = snapshot.devices.filter(\.isConnected).count
        let description: String
        switch snapshot.status {
        case .running:
            if connected > 0 {
                description = "Phantom running, \(connected) device\(connected == 1 ? "" : "s") connected"
            } else {
                description = "Phantom running"
            }
        case .connecting:
            description = "Phantom connecting"
        case .stopped:
            description = "Phantom stopped"
        case .error:
            description = "Phantom error"
        }
        statusItem.button?.setAccessibilityLabel(description)
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        menu.removeAllItems()
        let snapshot = daemonState.snapshot

        addStatusHeader(snapshot)
        menu.addItem(.separator())

        switch snapshot.status {
        case .stopped:
            addStoppedItems()
        case .error(let msg):
            addErrorItems(msg)
        case .connecting:
            let item = NSMenuItem(title: "Connecting\u{2026}", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .running:
            addRunningItems(snapshot)
        }

        menu.addItem(.separator())
        addFooterItems()
    }

    private func addStatusHeader(_ snapshot: DaemonSnapshot) {
        let item = NSMenuItem()
        let hosting = NSHostingView(rootView: StatusHeaderView(snapshot: snapshot))
        hosting.frame.size = hosting.fittingSize
        item.view = hosting
        menu.addItem(item)
    }

    private func addStoppedItems() {
        let item = NSMenuItem(
            title: "Start Daemon",
            action: #selector(startDaemon),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    private func addErrorItems(_ message: String) {
        let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        if message.count > 50 {
            errorItem.title = String(message.prefix(47)) + "\u{2026}"
            errorItem.toolTip = message
        } else {
            errorItem.title = message
        }
        menu.addItem(errorItem)

        let retryItem = NSMenuItem(
            title: "Retry",
            action: #selector(retryConnection),
            keyEquivalent: ""
        )
        retryItem.target = self
        menu.addItem(retryItem)
    }

    private func addRunningItems(_ snapshot: DaemonSnapshot) {
        if !snapshot.devices.isEmpty {
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: "Devices"))
            } else {
                let header = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }

            for device in snapshot.devices {
                menu.addItem(makeDeviceItem(device))
            }
            menu.addItem(.separator())
        }

        if !snapshot.sessions.isEmpty {
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: "Sessions"))
            } else {
                let header = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }

            for session in snapshot.sessions {
                menu.addItem(makeSessionItem(session))
            }
            menu.addItem(.separator())
        }

        let pairItem = NSMenuItem(
            title: "Pair New Device\u{2026}",
            action: #selector(pairNewDevice),
            keyEquivalent: "n"
        )
        pairItem.target = self
        pairItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(pairItem)
    }

    private func makeDeviceItem(_ device: DeviceInfo) -> NSMenuItem {
        let item = NSMenuItem(title: device.deviceName, action: nil, keyEquivalent: "")

        let color: NSColor = device.isConnected ? .systemGreen : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        item.image = NSImage(
            systemSymbolName: "iphone",
            accessibilityDescription: device.isConnected ? "Connected" : "Disconnected"
        )?.withSymbolConfiguration(config)
        item.indentationLevel = 1

        let sub = NSMenu()

        if device.isConnected {
            let status = NSMenuItem(title: "Connected", action: nil, keyEquivalent: "")
            status.isEnabled = false
            sub.addItem(status)
            sub.addItem(.separator())
        } else if let lastSeen = device.lastSeen, !lastSeen.isEmpty {
            let seen = NSMenuItem(title: "Last seen: \(lastSeen)", action: nil, keyEquivalent: "")
            seen.isEnabled = false
            sub.addItem(seen)
            sub.addItem(.separator())
        }

        let copy = NSMenuItem(
            title: "Copy Device ID",
            action: #selector(copyToPasteboard(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        copy.representedObject = device.deviceId
        sub.addItem(copy)

        sub.addItem(.separator())

        let revoke = NSMenuItem(
            title: "Revoke Device",
            action: #selector(revokeDevice(_:)),
            keyEquivalent: ""
        )
        revoke.target = self
        revoke.representedObject = device.deviceId
        sub.addItem(revoke)

        item.submenu = sub
        return item
    }

    private func makeSessionItem(_ session: SessionInfo) -> NSMenuItem {
        let shellName = session.shell.components(separatedBy: "/").last ?? session.shell
        let shortId = String(session.id.prefix(8))

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: shellName,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        ))
        title.append(NSAttributedString(
            string: " \u{00B7} ",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        title.append(NSAttributedString(
            string: shortId,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize(for: .regular) - 1,
                    weight: .regular
                ),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))

        let item = NSMenuItem()
        item.attributedTitle = title

        let symbolColor: NSColor = session.alive ? .systemGreen : .systemRed
        let config = NSImage.SymbolConfiguration(paletteColors: [symbolColor])
        item.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: session.alive ? "Active session" : "Dead session"
        )?.withSymbolConfiguration(config)

        if session.attached {
            item.state = .on
        }
        item.indentationLevel = 1

        let sub = NSMenu()

        let statusText = session.attached ? "Attached" : (session.alive ? "Idle" : "Dead")
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        sub.addItem(status)
        sub.addItem(.separator())

        let copy = NSMenuItem(
            title: "Copy Session ID",
            action: #selector(copyToPasteboard(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        copy.representedObject = session.id
        sub.addItem(copy)

        sub.addItem(.separator())

        let destroy = NSMenuItem(
            title: "Destroy Session",
            action: #selector(destroySession(_:)),
            keyEquivalent: ""
        )
        destroy.target = self
        destroy.representedObject = session.id
        sub.addItem(destroy)

        item.submenu = sub
        return item
    }

    private func addFooterItems() {
        if let error = setupManager.setupError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Phantom",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func startDaemon() {
        Task { await daemonState.startDaemon() }
    }

    @objc private func retryConnection() {
        daemonState.refresh()
    }

    @objc private func pairNewDevice() {
        if let existing = pairingPanel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Pair New Device"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        let content = PairingView().environmentObject(daemonState)
        panel.contentView = NSHostingView(rootView: content)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pairingPanel = panel
    }

    @objc private func copyToPasteboard(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func revokeDevice(_ sender: NSMenuItem) {
        guard let deviceId = sender.representedObject as? String else { return }
        daemonState.revokeDevice(deviceId)
    }

    @objc private func destroySession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        daemonState.destroySession(sessionId)
    }

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Phantom Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let content = SettingsView().environmentObject(daemonState)
        window.contentView = NSHostingView(rootView: content)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quitApp() {
        Task {
            if daemonState.snapshot.status.isRunning {
                await daemonState.stopDaemon()
            }
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        daemonState.startPolling(fast: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        if daemonState.snapshot.status == .stopped {
            daemonState.stopPolling()
        } else {
            daemonState.startPolling(fast: false)
        }
    }
}
