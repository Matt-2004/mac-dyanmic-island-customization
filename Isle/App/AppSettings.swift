import Foundation
import Combine

/// UserDefaults-backed preferences shared by the app.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let hoverDelay = "hoverDelay"
        static let peekDuration = "peekDuration"
        static let blockedApps = "blockedApps"
        static let axDumpEnabled = "axDumpEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let skipAccessibilityOnboarding = "skipAccessibilityOnboarding"
        static let usernotedFallbackEnabled = "usernotedFallbackEnabled"
        static let webIconsEnabled = "webIconsEnabled"
        static let chargingPeekEnabled = "chargingPeekEnabled"
        static let lowBatteryAlertsEnabled = "lowBatteryAlertsEnabled"
        static let chargingIndicatorEnabled = "chargingIndicatorEnabled"
        static let airpodsPeekEnabled = "airpodsPeekEnabled"
        static let bluetoothScope = "bluetoothScope"
        static let skipBluetoothOnboarding = "skipBluetoothOnboarding"
        static let closeSystemBanners = "closeSystemBanners"
        static let spotifyEnabled = "spotifyEnabled"
        static let fetchMissingArtwork = "fetchMissingArtwork"
        static let hideInFullScreen = "hideInFullScreen"
        static let runAsService = "runAsService"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    private let defaults: UserDefaults

    /// Seconds the pointer must rest on the compact island before it expands.
    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Key.hoverDelay) }
    }

    /// Seconds a notification peek stays visible.
    @Published var peekDuration: Double {
        didSet { defaults.set(peekDuration, forKey: Key.peekDuration) }
    }

    /// Apps whose notifications never peek. Keys are bundle IDs (or app names when unknown).
    @Published var blockedApps: [String] {
        didSet { defaults.set(blockedApps, forKey: Key.blockedApps) }
    }

    /// Debug: append the Notification Center AX tree to ~/Library/Logs/Isle/ax-dump.txt on every change.
    @Published var axDumpEnabled: Bool {
        didSet { defaults.set(axDumpEnabled, forKey: Key.axDumpEnabled) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// User chose "Not Now" in the Accessibility onboarding; don't show it at launch again.
    @Published var skipAccessibilityOnboarding: Bool {
        didSet { defaults.set(skipAccessibilityOnboarding, forKey: Key.skipAccessibilityOnboarding) }
    }

    /// Also read notifications from the usernoted database (needs Full Disk Access). Off by default.
    @Published var usernotedFallbackEnabled: Bool {
        didSet { defaults.set(usernotedFallbackEnabled, forKey: Key.usernotedFallbackEnabled) }
    }

    /// Download icons for web services (Messenger, Gmail…) from their websites.
    @Published var webIconsEnabled: Bool {
        didSet { defaults.set(webIconsEnabled, forKey: Key.webIconsEnabled) }
    }

    /// Peek when the charger is plugged in / unplugged / battery full.
    @Published var chargingPeekEnabled: Bool {
        didSet { defaults.set(chargingPeekEnabled, forKey: Key.chargingPeekEnabled) }
    }

    /// Peek at 20 % and 10 % while unplugged.
    @Published var lowBatteryAlertsEnabled: Bool {
        didSet { defaults.set(lowBatteryAlertsEnabled, forKey: Key.lowBatteryAlertsEnabled) }
    }

    /// Show the compact island with a bolt while charging.
    @Published var chargingIndicatorEnabled: Bool {
        didSet { defaults.set(chargingIndicatorEnabled, forKey: Key.chargingIndicatorEnabled) }
    }

    /// Peek when AirPods (or other audio devices) connect / disconnect.
    @Published var airpodsPeekEnabled: Bool {
        didSet { defaults.set(airpodsPeekEnabled, forKey: Key.airpodsPeekEnabled) }
    }

    @Published var bluetoothScope: BluetoothScope {
        didSet { defaults.set(bluetoothScope.rawValue, forKey: Key.bluetoothScope) }
    }

    @Published var skipBluetoothOnboarding: Bool {
        didSet { defaults.set(skipBluetoothOnboarding, forKey: Key.skipBluetoothOnboarding) }
    }

    /// Close the macOS banner when Isle shows the notification (also removes it from Notification Center).
    @Published var closeSystemBanners: Bool {
        didSet { defaults.set(closeSystemBanners, forKey: Key.closeSystemBanners) }
    }

    /// Also follow Spotify (when it is running).
    @Published var spotifyEnabled: Bool {
        didSet { defaults.set(spotifyEnabled, forKey: Key.spotifyEnabled) }
    }

    /// Look up artwork on the iTunes Search API when the player provides none.
    @Published var fetchMissingArtwork: Bool {
        didSet { defaults.set(fetchMissingArtwork, forKey: Key.fetchMissingArtwork) }
    }

    /// Hide the island (except peeks) while a full-screen app is in front on the notch screen.
    @Published var hideInFullScreen: Bool {
        didSet { defaults.set(hideInFullScreen, forKey: Key.hideInFullScreen) }
    }

    /// Run as a launchd agent: start at login, restart after a crash.
    @Published var runAsService: Bool {
        didSet { defaults.set(runAsService, forKey: Key.runAsService) }
    }

    /// When off, Isle has no menu bar icon; opening Isle.app again shows Settings.
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    func isBlocked(_ key: String) -> Bool {
        blockedApps.contains(key)
    }

    func block(_ key: String) {
        guard !blockedApps.contains(key) else { return }
        blockedApps.append(key)
    }

    func unblock(_ key: String) {
        blockedApps.removeAll { $0 == key }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hoverDelay: 0.25,
            Key.peekDuration: 4.0,
            Key.blockedApps: [String](),
            Key.axDumpEnabled: false,
            Key.notificationsEnabled: true,
            Key.skipAccessibilityOnboarding: false,
            Key.usernotedFallbackEnabled: false,
            Key.webIconsEnabled: true,
            Key.chargingPeekEnabled: true,
            Key.lowBatteryAlertsEnabled: true,
            Key.chargingIndicatorEnabled: true,
            Key.airpodsPeekEnabled: true,
            Key.bluetoothScope: BluetoothScope.airpodsOnly.rawValue,
            Key.skipBluetoothOnboarding: false,
            Key.closeSystemBanners: false,
            Key.spotifyEnabled: true,
            Key.fetchMissingArtwork: true,
            Key.hideInFullScreen: true,
            Key.runAsService: true,
            Key.showMenuBarIcon: true
        ])
        hoverDelay = defaults.double(forKey: Key.hoverDelay)
        peekDuration = defaults.double(forKey: Key.peekDuration)
        blockedApps = defaults.stringArray(forKey: Key.blockedApps) ?? []
        axDumpEnabled = defaults.bool(forKey: Key.axDumpEnabled)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        skipAccessibilityOnboarding = defaults.bool(forKey: Key.skipAccessibilityOnboarding)
        usernotedFallbackEnabled = defaults.bool(forKey: Key.usernotedFallbackEnabled)
        webIconsEnabled = defaults.bool(forKey: Key.webIconsEnabled)
        chargingPeekEnabled = defaults.bool(forKey: Key.chargingPeekEnabled)
        lowBatteryAlertsEnabled = defaults.bool(forKey: Key.lowBatteryAlertsEnabled)
        chargingIndicatorEnabled = defaults.bool(forKey: Key.chargingIndicatorEnabled)
        airpodsPeekEnabled = defaults.bool(forKey: Key.airpodsPeekEnabled)
        bluetoothScope = BluetoothScope(rawValue: defaults.string(forKey: Key.bluetoothScope) ?? "") ?? .airpodsOnly
        skipBluetoothOnboarding = defaults.bool(forKey: Key.skipBluetoothOnboarding)
        closeSystemBanners = defaults.bool(forKey: Key.closeSystemBanners)
        spotifyEnabled = defaults.bool(forKey: Key.spotifyEnabled)
        fetchMissingArtwork = defaults.bool(forKey: Key.fetchMissingArtwork)
        hideInFullScreen = defaults.bool(forKey: Key.hideInFullScreen)
        runAsService = defaults.bool(forKey: Key.runAsService)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
    }
}
