import SwiftUI
import Combine

@main
struct PhantomBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window is opened manually via StatusBarController
        // to work reliably with LSUIElement agent apps.
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    let daemonState = DaemonState()
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
                description = "Phantom connected, \(connected) device\(connected == 1 ? "" : "s")"
            } else {
                description = "Phantom connected"
            }
        case .connecting:
            description = "Phantom connecting"
        case .stopped:
            description = "Phantom not connected"
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

        switch snapshot.status {
        case .stopped, .connecting:
            break
        case .error(let msg):
            menu.addItem(.separator())
            addErrorItems(msg)
        case .running:
            menu.addItem(.separator())
            addRunningItems(snapshot)
        }

        menu.addItem(.separator())
        addFooterItems()
    }

    private func addStatusHeader(_ snapshot: DaemonSnapshot) {
        let item = NSMenuItem()
        let view = StatusHeaderView(
            snapshot: snapshot,
            isTransitioning: daemonState.isTransitioning,
            onToggle: { [weak self] wantsRunning in
                self?.handleToggle(wantsRunning: wantsRunning)
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        item.view = hosting
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
        // Devices section
        let deviceCount = snapshot.devices.count
        let deviceTitle = deviceCount > 0 ? "Devices (\(deviceCount))" : "Devices"
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: deviceTitle))
        } else {
            let header = NSMenuItem(title: deviceTitle, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        if snapshot.devices.isEmpty {
            let empty = NSMenuItem(title: "No devices paired", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        } else {
            for device in snapshot.devices {
                menu.addItem(makeDeviceItem(device))
            }
        }
        menu.addItem(.separator())

        // Sessions section
        let aliveCount = snapshot.sessions.filter(\.alive).count
        let sessionTitle = aliveCount > 0 ? "Sessions (\(aliveCount))" : "Sessions"
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: sessionTitle))
        } else {
            let header = NSMenuItem(title: sessionTitle, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        if snapshot.sessions.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        } else {
            for session in snapshot.sessions {
                menu.addItem(makeSessionItem(session))
            }
        }
        menu.addItem(.separator())

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
            let displayTime: String
            if let date = parseISO8601(lastSeen) {
                displayTime = relativeTime(date)
            } else {
                displayTime = lastSeen
            }
            let seen = NSMenuItem(title: "Last seen: \(displayTime)", action: nil, keyEquivalent: "")
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
            title: "Remove Device",
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
            accessibilityDescription: session.alive ? "Active session" : "Ended session"
        )?.withSymbolConfiguration(config)

        if session.attached {
            item.state = .on
        }
        item.indentationLevel = 1

        let sub = NSMenu()

        let statusText = session.attached ? "Attached" : (session.alive ? "Idle" : "Ended")
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        sub.addItem(status)

        // Show device that created this session
        if let deviceId = session.createdByDeviceId {
            let devices = daemonState.snapshot.devices
            let deviceName = devices.first(where: { $0.deviceId == deviceId })?.deviceName ?? deviceId
            let source = NSMenuItem(title: "Created by: \(deviceName)", action: nil, keyEquivalent: "")
            source.isEnabled = false
            sub.addItem(source)
        }

        // Show last activity
        if let activityStr = session.lastActivityAt, let activity = parseISO8601(activityStr) {
            let ago = relativeTime(activity)
            let activityItem = NSMenuItem(title: "Active: \(ago)", action: nil, keyEquivalent: "")
            activityItem.isEnabled = false
            sub.addItem(activityItem)
        }

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
            title: "End Session",
            action: #selector(destroySession(_:)),
            keyEquivalent: ""
        )
        destroy.target = self
        destroy.representedObject = session.id
        sub.addItem(destroy)

        item.submenu = sub
        return item
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }()
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
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
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    private func handleToggle(wantsRunning: Bool) {
        guard !daemonState.isTransitioning else { return }

        if wantsRunning {
            // Let the toggle animation play, then dismiss.
            dismissMenuAfterDelay()
            Task { await daemonState.startDaemon() }
            return
        }

        // Stopping — confirm when there are active sessions or connected devices.
        let snapshot = daemonState.snapshot
        let activeSessions = snapshot.sessions.filter(\.alive).count
        let connectedDevices = snapshot.devices.filter(\.isConnected).count

        if activeSessions > 0 || connectedDevices > 0 {
            let alert = NSAlert()
            alert.messageText = "Stop Phantom?"
            var parts: [String] = []
            if connectedDevices > 0 {
                parts.append("\(connectedDevices) connected device\(connectedDevices == 1 ? "" : "s")")
            }
            if activeSessions > 0 {
                parts.append("\(activeSessions) active session\(activeSessions == 1 ? "" : "s")")
            }
            alert.informativeText = "This will disconnect \(parts.joined(separator: " and "))."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stop")
            alert.addButton(withTitle: "Cancel")
            // The modal alert implicitly closes the menu.
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else {
            dismissMenuAfterDelay()
        }

        Task { await daemonState.stopDaemon() }
    }

    /// Let the toggle animation play (~150ms) then close the menu.
    /// The menu rebuilds with the correct state on next open.
    private func dismissMenuAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.menu.cancelTrackingWithoutAnimation()
        }
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
        let deviceName = daemonState.snapshot.devices
            .first(where: { $0.deviceId == deviceId })?.deviceName ?? deviceId

        let alert = NSAlert()
        alert.messageText = "Remove \(deviceName)?"
        alert.informativeText = "This device will need to pair again via QR code to reconnect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        daemonState.revokeDevice(deviceId)
    }

    @objc private func destroySession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }

        let alert = NSAlert()
        alert.messageText = "End this session?"
        alert.informativeText = "The terminal session will close. Any unsaved work in the shell will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        daemonState.destroySession(sessionId)
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Phantom Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView().environmentObject(daemonState)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quitApp() {
        // Quit PhantomBar only — daemon continues running as a LaunchAgent.
        // Active sessions are daemon-owned and survive the menu bar app quitting.
        NSApplication.shared.terminate(nil)
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
