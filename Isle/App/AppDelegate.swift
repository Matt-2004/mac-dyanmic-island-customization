import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var store = IslandStateStore(settings: settings)
    private lazy var debugPlayer = DebugPlayer(store: store)
    private var settingsWindow: SettingsWindowController?
    private var musicService: MusicService?
    private var notifications: NotificationCoordinator?
    private var devices: DevicesCoordinator?
    private var onboarding: AccessibilityOnboardingWindowController?
    private var windowController: NotchWindowController?
    private var statusMenu: StatusMenuController?
    private let backgroundService = BackgroundService()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = BackgroundService.isServiceInstance ? "service" : "app"
        FileLog.write("launch: Isle \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") pid \(ProcessInfo.processInfo.processIdentifier) as \(mode) from \(Bundle.main.bundlePath)")

        switch SingleInstance.decide() {
        case .proceed:
            start()
        case .waitForOthers(let others):
            FileLog.write("instance: asking \(others.count) running copy(ies) to quit")
            SingleInstance.askOthersToQuit()
            SingleInstance.waitUntilGone(others) { [weak self] in self?.start() }
        case .exitAfterShowingSettings:
            // Register the service first if needed (e.g. the running copy is a development
            // build); launchd's instance then takes over from every other copy.
            backgroundService.applyPreference(settings.runAsService)
            FileLog.write("instance: already running; showing its Settings")
            SingleInstance.askRunningCopyToShowSettings()
            NSApp.terminate(nil)
        }
    }

    private func start() {
        SingleInstance.listen { [weak self] in self?.settingsWindow?.show() }
        backgroundService.applyPreference(settings.runAsService)
        settings.$runAsService
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] wanted in self?.backgroundService.setEnabled(wanted) }
            .store(in: &cancellables)

        store.debugController = debugPlayer

        let musicService = MusicService { [weak self] nowPlaying in
            self?.store.updateLiveNowPlaying(nowPlaying)
        }
        store.liveController = musicService
        self.musicService = musicService
        musicService.start()
        settings.$spotifyEnabled
            .sink { [weak musicService] enabled in musicService?.setSpotifyEnabled(enabled) }
            .store(in: &cancellables)
        settings.$fetchMissingArtwork
            .sink { [weak musicService] enabled in musicService?.fetchMissingArtwork = enabled }
            .store(in: &cancellables)
        // Re-sync position every second while the expanded player is visible.
        store.$state
            .map { $0 == .expanded }
            .removeDuplicates()
            .sink { [weak musicService] expanded in musicService?.setFastResync(expanded) }
            .store(in: &cancellables)

        let devices = DevicesCoordinator(store: store, settings: settings)
        self.devices = devices
        devices.start()

        let notifications = NotificationCoordinator(store: store, settings: settings)
        self.notifications = notifications
        let onboarding = AccessibilityOnboardingWindowController(coordinator: notifications, settings: settings)
        self.onboarding = onboarding
        settingsWindow = SettingsWindowController(
            settings: settings,
            notifications: notifications,
            devices: devices,
            backgroundService: backgroundService,
            showOnboarding: { onboarding.show() }
        )
        notifications.startIfPossible()
        if !notifications.isAccessibilityTrusted && settings.notificationsEnabled && !settings.skipAccessibilityOnboarding {
            onboarding.show()
        }

        let windowController = NotchWindowController(store: store, settings: settings)
        windowController.show()
        self.windowController = windowController

        statusMenu = StatusMenuController(
            store: store,
            debugPlayer: debugPlayer,
            musicService: musicService,
            notifications: notifications,
            devices: devices,
            openSettings: { [weak self] in self?.settingsWindow?.show() },
            showOnboarding: { onboarding.show() }
        )
        settings.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] visible in self?.statusMenu?.setVisible(visible) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.tearDown()
        musicService?.stop()
        notifications?.stop()
        devices?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return false
    }
}
