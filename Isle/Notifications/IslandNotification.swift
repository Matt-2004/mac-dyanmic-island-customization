import AppKit

/// A notification captured from the system and shown in the island.
struct IslandNotification: Identifiable, Equatable {
    let id: UUID
    /// Bundle identifier of the posting app when it could be resolved.
    var bundleIdentifier: String?
    var appName: String
    var title: String
    var subtitle: String?
    var body: String?
    var date: Date
    /// Which source reported it ("ax", "usernoted", "debug"); used to merge cross-source duplicates.
    var source: String

    init(
        id: UUID = UUID(),
        bundleIdentifier: String?,
        appName: String,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        date: Date = Date(),
        source: String = "debug"
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
        self.source = source
    }

    /// Key used for per-app blocklisting. Falls back to the display name.
    var blocklistKey: String {
        bundleIdentifier ?? appName
    }

    /// Fingerprint used to drop duplicate deliveries of the same banner.
    var fingerprint: String {
        [blocklistKey, title, subtitle ?? "", body ?? ""].joined(separator: "\u{1F}")
    }

}
