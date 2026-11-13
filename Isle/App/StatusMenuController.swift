import AppKit
import Combine

/// Menu bar icon with Settings, the Debug state menu, and Quit.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: IslandStateStore
    private let debugPlayer: DebugPlayer
    private let musicService: MusicService
    private let notifications: NotificationCoordinator
    private let devices: DevicesCoordinator
    private let bluetoothItem = NSMenuItem(title: "Set Up AirPods (Bluetooth)…", action: nil, keyEquivalent: "")
    private let showOnboarding: () -> Void
    private let accessibilityItem = NSMenuItem(title: "Set Up Notifications…", action: nil, keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent Notifications", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu(title: "Recent Notifications")
    private let openSettings: () -> Void
    private let menu = NSMenu()
    private var stateItems: [IslandState: NSMenuItem] = [:]
    private let liveItem = NSMenuItem(title: "Use Live Data", action: nil, keyEquivalent: "")
    private let currentStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let musicStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let automationItem = NSMenuItem(title: "Grant Automation Access…", action: nil, keyEquivalent: "")

    init(store: IslandStateStore, debugPlayer: DebugPlayer, musicService: MusicService,
         notifications: NotificationCoordinator,
         devices: DevicesCoordinator,
         openSettings: @escaping () -> Void, showOnboarding: @escaping () -> Void) {
        self.notifications = notifications
        self.devices = devices
        self.showOnboarding = showOnboarding
        self.store = store
        self.debugPlayer = debugPlayer
        self.musicService = musicService
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isle")
            button.image?.isTemplate = true
        }
        buildMenu()
        statusItem.menu = menu
    }

    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        currentStateItem.isEnabled = false
        menu.addItem(currentStateItem)
        musicStatusItem.isEnabled = false
        menu.addItem(musicStatusItem)
        automationItem.action = #selector(openAutomationSettings)
        automationItem.target = self
        menu.addItem(automationItem)
        accessibilityItem.action = #selector(openOnboarding)
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        bluetoothItem.action = #selector(openBluetoothOnboarding)
        bluetoothItem.target = self
        menu.addItem(bluetoothItem)
        menu.addItem(.separator())

        recentMenu.autoenablesItems = false
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = makeDebugMenu()
        menu.addItem(debugItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Isle", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeDebugMenu() -> NSMenu {
        let debugMenu = NSMenu(title: "Debug")
        debugMenu.autoenablesItems = false

        let header = NSMenuItem(title: "Force State", action: nil, keyEquivalent: "")
        header.isEnabled = false
        debugMenu.addItem(header)

        for (index, state) in IslandState.allCases.enumerated() {
            let item = NSMenuItem(title: state.displayName, action: #selector(forceState(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = state.rawValue
            item.indentationLevel = 1
            debugMenu.addItem(item)
            stateItems[state] = item
        }

        debugMenu.addItem(.separator())
        liveItem.action = #selector(useLiveData)
        liveItem.target = self
        debugMenu.addItem(liveItem)

        let nextItem = NSMenuItem(title: "Debug Player: Next Track", action: #selector(debugNext), keyEquivalent: "")
        nextItem.target = self
        debugMenu.addItem(nextItem)

        let toggleItem = NSMenuItem(title: "Debug Player: Play/Pause", action: #selector(debugPlayPause), keyEquivalent: "")
        toggleItem.target = self
        debugMenu.addItem(toggleItem)

        debugMenu.addItem(.separator())
        let peeks: [(String, Int)] = [
            ("Peek: Charger Plugged In", 0),
            ("Peek: Charger Unplugged", 1),
            ("Peek: Fully Charged", 2),
            ("Peek: Low Battery 20%", 3),
            ("Peek: Low Battery 10% (critical)", 4),
            ("Peek: AirPods Connected", 10),
            ("Peek: AirPods Disconnected", 11)
        ]
        for (title, tag) in peeks {
            let item = NSMenuItem(title: title, action: #selector(debugDevicePeek(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            debugMenu.addItem(item)
        }

        debugMenu.addItem(.separator())
        let dumpItem = NSMenuItem(title: "Dump Notification AX Tree Now", action: #selector(dumpAXTree), keyEquivalent: "")
        dumpItem.target = self
        debugMenu.addItem(dumpItem)
        let revealItem = NSMenuItem(title: "Show ax-dump.txt in Finder", action: #selector(revealDump), keyEquivalent: "")
        revealItem.target = self
        debugMenu.addItem(revealItem)

        return debugMenu
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        currentStateItem.title = "Island: \(store.state.displayName)"
        if let track = musicService.nowPlaying {
            let artist = track.artist.isEmpty ? "" : " — \(track.artist)"
            let player = musicService.activePlayer?.displayName ?? "Music"
            musicStatusItem.title = "\(player): \(musicService.status.displayText) · \(track.title)\(artist)"
        } else {
            musicStatusItem.title = "Music: \(musicService.status.displayText)"
        }
        automationItem.isHidden = musicService.status != .notAuthorized
        accessibilityItem.isHidden = notifications.isAccessibilityTrusted
        bluetoothItem.isHidden = devices.bluetooth.permission != .denied
        rebuildRecentMenu()
        for (state, item) in stateItems {
            item.state = (store.isDebugOverrideActive && store.state == state) ? .on : .off
        }
        liveItem.state = store.isDebugOverrideActive ? .off : .on
    }

    // MARK: Actions

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func forceState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let state = IslandState(rawValue: raw) else { return }
        switch state {
        case .idle:
            store.debugShowIdle()
        case .battery:
            // The battery wing comes from live power data.
            store.debugClearOverrides()
        case .gesture:
            store.setGestureStatus(.listening(.two))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.store.setGestureStatus(nil)
            }
        case .compact:
            store.debugShowCompact(sample: debugPlayer.sample())
        case .expanded:
            store.debugShowExpanded(sample: debugPlayer.sample())
        case .peek:
            store.presentPeek(DebugSamples.notification())
        case .powerPeek:
            devices.debugPowerPeek(.pluggedIn)
        case .airpodsPeek:
            devices.debugAirPodsPeek(connected: true)
        }
    }

    @objc private func debugDevicePeek(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: devices.debugPowerPeek(.pluggedIn)
        case 1: devices.debugPowerPeek(.unplugged)
        case 2: devices.debugPowerPeek(.fullyCharged)
        case 3: devices.debugPowerPeek(.lowBattery(threshold: 20))
        case 4: devices.debugPowerPeek(.lowBattery(threshold: 10))
        case 10: devices.debugAirPodsPeek(connected: true)
        case 11: devices.debugAirPodsPeek(connected: false)
        default: break
        }
    }

    @objc private func openBluetoothOnboarding() {
        devices.showBluetoothOnboarding()
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let history = notifications.history
        recentItem.title = history.isEmpty ? "Recent Notifications" : "Recent Notifications (\(history.count))"
        guard !history.isEmpty else {
            let empty = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        for (index, item) in history.enumerated() {
            var text = "\(item.appName) — \(item.title)"
            if let body = item.body, !body.isEmpty {
                text += ": \(body)"
            }
            if text.count > 70 {
                text = String(text.prefix(69)) + "…"
            }
            let menuItem = NSMenuItem(title: "\(formatter.string(from: item.date))  \(text)",
                                      action: #selector(openRecent(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            let icon = AppIconProvider.shared.icon(for: item).flatMap { $0.copy() as? NSImage }
                ?? LetterBadgeStyle.image(for: item.appName, size: 16)
            icon.size = NSSize(width: 16, height: 16)
            menuItem.image = icon
            recentMenu.addItem(menuItem)
        }
        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear All", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        let history = notifications.history
        guard history.indices.contains(sender.tag) else { return }
        notifications.open(history[sender.tag])
    }

    @objc private func clearRecent() {
        notifications.clearHistory()
    }

    @objc private func openOnboarding() {
        showOnboarding()
    }

    @objc private func dumpAXTree() {
        notifications.dumpAXTreeNow { written in
            if written {
                NSWorkspace.shared.activateFileViewerSelecting([AXTreeDumper.dumpFileURL])
            } else {
                NSSound.beep()
            }
        }
    }

    @objc private func revealDump() {
        NSWorkspace.shared.activateFileViewerSelecting([AXTreeDumper.dumpFileURL])
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func useLiveData() {
        store.debugClearOverrides()
    }

    @objc private func debugNext() {
        debugPlayer.nextTrack()
    }

    @objc private func debugPlayPause() {
        debugPlayer.playPause()
    }
}
