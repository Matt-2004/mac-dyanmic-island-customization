import Foundation

/// Something that observes system notifications and reports them to Isle.
protocol NotificationSource: AnyObject {
    /// Human-readable name for logs and settings.
    var name: String { get }
    /// Whether the source is currently attached and observing.
    var isRunning: Bool { get }
    /// Begins observing. `handler` is always called on the main thread.
    func start(handler: @escaping (IslandNotification) -> Void)
    func stop()
}
