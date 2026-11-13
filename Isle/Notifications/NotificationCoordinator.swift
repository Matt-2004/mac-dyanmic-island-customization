import AppKit
import ApplicationServices
import Combine
import OSLog

/// Owns the notification sources, permission state, history (last 20) and
/// blocklist filtering, and forwards accepted notifications to the island.
@MainActor
final class NotificationCoordinator: ObservableObject {
    static let historyLimit = 20

    @Published private(set) var history: [IslandNotification] = []
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var usernotedStatus: UsernotedNotificationSource.Status = .stopped

    private let store: IslandStateStore
    private let settings: AppSettings
    private let accessibilitySource = AccessibilityNotificationSource()
    private let usernotedSource = UsernotedNotificationSource()
    private let log = Logger(subsystem: "com.wai.Isle", category: "notifications")
    private var cancellables = Set<AnyCancellable>()
    private var trustPollTimer: Timer?

    init(store: IslandStateStore, settings: AppSettings) {
        self.store = store
        self.settings = settings

        store.openNotificationHandler = { [weak self] notification in
            self?.open(notification)
        }

        settings.$axDumpEnabled
            .sink { [weak self] enabled in self?.accessibilitySource.dumpEnabled = enabled }
            .store(in: &cancellables)

        settings.$closeSystemBanners
            .sink { [weak self] enabled in self?.accessibilitySource.closesSystemBanners = enabled }
            .store(in: &cancellables)

        settings.$webIconsEnabled
            .sink { enabled in AppIconProvider.shared.webIconsEnabled = enabled }
            .store(in: &cancellables)

        usernotedSource.onStatusChange = { [weak self] status in
            MainActor.assumeIsolated { self?.usernotedStatus = status }
        }

        settings.$notificationsEnabled
            .merge(with: settings.$usernotedFallbackEnabled)
            .dropFirst(2)
            .sink { [weak self] _ in
                // Re-evaluate on the next run-loop pass, after the setting has been stored.
                DispatchQueue.main.async { self?.startIfPossible() }
            }
            .store(in: &cancellables)
    }

    /// Starts observing if permission is granted and notifications are enabled.
    func startIfPossible() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        FileLog.write("notifications: enabled=\(settings.notificationsEnabled) axTrusted=\(isAccessibilityTrusted) running=\(accessibilitySource.isRunning)")
        updateUsernotedSource()
        guard settings.notificationsEnabled else {
            if accessibilitySource.isRunning {
                accessibilitySource.stop()
            }
            return
        }
        guard isAccessibilityTrusted else {
            startTrustPolling()
            return
        }
        stopTrustPolling()
        guard !accessibilitySource.isRunning else { return }
        accessibilitySource.dumpEnabled = settings.axDumpEnabled
        accessibilitySource.start { [weak self] notification in
            MainActor.assumeIsolated { self?.receive(notification) }
        }
        log.notice("Accessibility notification source started")
    }

    func stop() {
        accessibilitySource.stop()
        usernotedSource.stop()
        stopTrustPolling()
    }

    /// Shows the system Accessibility prompt (adds Isle to the list) and opens System Settings.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if !isAccessibilityTrusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTrustPolling()
    }

    func dumpAXTreeNow(completion: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(false)
            return
        }
        accessibilitySource.dumpNow(completion: completion)
    }

    // MARK: History

    func remove(_ notification: IslandNotification) {
        history.removeAll { $0.id == notification.id }
        if store.activeNotification?.id == notification.id {
            store.dismissPeek()
        }
    }

    func clearHistory() {
        history.removeAll()
    }

    func open(_ notification: IslandNotification) {
        guard let bundleID = notification.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func retryUsernoted() {
        if usernotedSource.isRunning {
            usernotedSource.stop()
        }
        updateUsernotedSource()
    }

    // MARK: Private

    /// The usernoted fallback runs alongside Accessibility when enabled; duplicates are merged in `receive`.
    private func updateUsernotedSource() {
        let shouldRun = settings.notificationsEnabled && settings.usernotedFallbackEnabled
        if shouldRun, !usernotedSource.isRunning {
            usernotedSource.start { [weak self] notification in
                MainActor.assumeIsolated { self?.receive(notification) }
            }
        } else if !shouldRun, usernotedSource.isRunning {
            usernotedSource.stop()
        }
    }

    /// The same notification reported by *both* sources (Accessibility and usernoted):
    /// same app + title + body within 10 s from a different source. Two identical
    /// messages from the same source are two notifications and both peek.
    private func isDuplicate(_ notification: IslandNotification) -> Bool {
        history.contains { existing in
            existing.source != notification.source
                && abs(notification.date.timeIntervalSince(existing.date)) < 10
                && existing.title == notification.title
                && (existing.body ?? "") == (notification.body ?? "")
                && (existing.blocklistKey == notification.blocklistKey || existing.appName == notification.appName)
        }
    }

    private func receive(_ notification: IslandNotification) {
        guard settings.notificationsEnabled else { return }
        if settings.isBlocked(notification.blocklistKey) || settings.isBlocked(notification.appName) {
            FileLog.write("notifications: blocked \(notification.appName)")
            log.notice("Blocked notification from \(notification.appName, privacy: .public)")
            return
        }
        if isDuplicate(notification) {
            return
        }
        FileLog.write("notifications: peek from \(notification.appName) (\(notification.bundleIdentifier ?? "no bundle id"))")
        // Start resolving the icon (may download a web service icon) before the peek renders.
        _ = AppIconProvider.shared.icon(for: notification)
        history.insert(notification, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        store.presentPeek(notification)
    }

    private func startTrustPolling() {
        guard trustPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.isAccessibilityTrusted {
                    self.isAccessibilityTrusted = trusted
                }
                if trusted {
                    self.startIfPossible()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func stopTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
    }
}
