import ApplicationServices
import AppKit

/// A banner found in the Notification Center accessibility tree.
struct ParsedBanner {
    var appName: String?
    var bundleIdentifier: String?
    var title: String
    var subtitle: String?
    var body: String?
    /// True when the banner sits inside the open Notification Center panel
    /// (history), not a freshly delivered banner.
    var isInHistoryPanel: Bool
    /// The banner's own AXIdentifier: unique per delivered notification
    /// (a UUID, a message id, …). Nil if macOS didn't provide one.
    var identifier: String?
    /// Names of the banner's AX actions (e.g. the custom "Close" action).
    var actions: [String] = []
    /// Live element for performing actions; nil in tests.
    var element: AXUIElement?

    var fingerprint: String {
        [bundleIdentifier ?? appName ?? "", title, subtitle ?? "", body ?? ""].joined(separator: "\u{1F}")
    }

    /// Identity used to decide whether a banner is new: the per-notification identifier when
    /// available, otherwise the content. Two identical messages are still two notifications.
    var identity: String {
        if let identifier, !identifier.isEmpty { return "id:" + identifier }
        return "fp:" + fingerprint
    }

    /// The custom AX action that closes the banner ("Name:Close\nTarget:…").
    var closeAction: String? {
        actions.first { action in
            action == "AXDismiss" || action.hasPrefix("Name:Close") || action.hasPrefix("Name:Clear")
        }
    }
}

/// Extracts banners from a snapshot of the NotificationCenter process's AX tree.
///
/// Heuristics (tuned with `ax-dump.txt` on macOS 26):
/// - A banner is the innermost element whose subrole starts with
///   `AXNotificationCenterBanner` or `AXNotificationCenterAlert` (but not "…Stack").
/// - Fallback: an `AXGroup` whose child static texts carry the identifiers `title` / `body`.
/// - Texts come from `AXStaticText` values, preferring the `title` / `subtitle` / `body`
///   identifiers; otherwise first text = title, remaining = body.
/// - Browser web-app banners (Gmail, Messenger in Brave/Chrome) put the app name in
///   `title` and a generic "Notification" in `body`; sender and message are rebuilt from
///   the banner description "App, Sender, Message".
/// - The open Notification Center panel is detected via a non-empty `widgets-overlay-view`;
///   banners found there are history, not new.
enum BannerParser {
    private static let bannerSubrolePrefixes = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]

    /// Reads the live tree and parses it. Call from the AX worker thread.
    static func banners(in app: AXUIElement) -> [ParsedBanner] {
        let windows = AX.elements(app, kAXWindowsAttribute).map { AXNode.capture($0) }
        return banners(inWindows: windows, resolveBundleID: AppNameResolver.bundleIdentifier(forAppName:))
    }

    /// Pure parsing entry point (used by tests).
    static func banners(inWindows windows: [AXNode], resolveBundleID: (String) -> String?) -> [ParsedBanner] {
        var results: [ParsedBanner] = []
        for window in windows {
            let isPanel = isPanelOpen(in: window)
            var candidates: [AXNode] = []
            collectCandidates(window, into: &candidates)
            if candidates.isEmpty {
                collectFallbackCandidates(window, into: &candidates)
            }
            for candidate in candidates {
                if var banner = parse(candidate, resolveBundleID: resolveBundleID) {
                    banner.isInHistoryPanel = isPanel
                    results.append(banner)
                }
            }
        }
        return results
    }

    /// Human-readable description of what the parser found, appended to dumps.
    static func summary(_ banners: [ParsedBanner]) -> String {
        guard !banners.isEmpty else { return "no banners found" }
        return banners.enumerated().map { index, banner in
            "#\(index + 1) app=\(banner.appName ?? "nil") bundle=\(banner.bundleIdentifier ?? "nil") "
                + "title=\"\(banner.title)\" subtitle=\"\(banner.subtitle ?? "")\" body=\"\(banner.body ?? "")\" "
                + "panel=\(banner.isInHistoryPanel) id=\(banner.identifier ?? "nil") close=\(banner.closeAction != nil)"
        }.joined(separator: "\n")
    }

    // MARK: Candidate discovery

    /// On macOS 26 banners and the Notification Center panel share one full-screen
    /// AXSystemDialog window. While only banners show, "widgets-overlay-view" is 0×0;
    /// it gets a real size when the panel (with its widgets) is open.
    static func isPanelOpen(in window: AXNode) -> Bool {
        guard let overlay = window.first(where: { $0.identifier == "widgets-overlay-view" }),
              let frame = overlay.frame else { return false }
        return frame.width > 1 && frame.height > 1
    }

    private static func isBannerSubrole(_ subrole: String?) -> Bool {
        guard let subrole else { return false }
        return bannerSubrolePrefixes.contains { subrole.hasPrefix($0) } && !subrole.hasSuffix("Stack")
    }

    /// Collects innermost nodes with a banner subrole. Returns whether any were found in the subtree.
    @discardableResult
    private static func collectCandidates(_ node: AXNode, into result: inout [AXNode]) -> Bool {
        var foundBelow = false
        for child in node.children where collectCandidates(child, into: &result) {
            foundBelow = true
        }
        if !foundBelow, isBannerSubrole(node.subrole) {
            result.append(node)
            return true
        }
        return foundBelow
    }

    private static func collectFallbackCandidates(_ node: AXNode, into result: inout [AXNode]) {
        if node.role == kAXGroupRole as String {
            let ids = Set(node.children.compactMap(\.identifier))
            if ids.contains("title") || ids.contains("body") {
                result.append(node)
                return
            }
        }
        for child in node.children {
            collectFallbackCandidates(child, into: &result)
        }
    }

    // MARK: Parsing

    private struct TextNode {
        let identifier: String?
        let value: String
    }

    private static func parse(_ banner: AXNode, resolveBundleID: (String) -> String?) -> ParsedBanner? {
        var texts: [TextNode] = []
        var imageDescriptions: [String] = []
        collectTexts(banner, depth: 0, texts: &texts, images: &imageDescriptions)

        func text(_ identifier: String) -> String? {
            texts.first { $0.identifier == identifier }?.value
        }

        var title = text("title")
        var subtitle = text("subtitle")
        var body = text("body")
        if title == nil && body == nil {
            let values = texts.map(\.value)
            title = values.first
            if values.count >= 3 {
                subtitle = values[1]
                body = values[2...].joined(separator: "\n")
            } else if values.count == 2 {
                body = values[1]
            }
        }

        let description = banner.descriptionText ?? banner.title
        var appName: String?

        if let titleText = title, let description,
           let rebuilt = rebuildFromDescription(description, appName: titleText) {
            appName = titleText
            title = rebuilt.sender
            subtitle = nil
            body = rebuilt.message
        } else {
            appName = resolveAppName(description: description, images: imageDescriptions,
                                     title: title, body: body, resolveBundleID: resolveBundleID)
        }
        let bundleIdentifier = appName.flatMap(resolveBundleID)

        let finalTitle = (title ?? appName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalTitle.isEmpty || !(body ?? "").isEmpty else { return nil }

        return ParsedBanner(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: finalTitle,
            subtitle: subtitle,
            body: body,
            isInHistoryPanel: false,
            identifier: banner.identifier,
            actions: banner.actions,
            element: banner.element
        )
    }

    /// Web-app banners: description is "App, Sender, Message" where the message itself may
    /// contain ", ". Only the first two separators are structural; the rest is kept verbatim.
    static func rebuildFromDescription(_ description: String, appName: String) -> (sender: String, message: String?)? {
        let prefix = appName + ", "
        guard description.hasPrefix(prefix) else { return nil }
        let remainder = description.dropFirst(prefix.count)
        guard !remainder.isEmpty else { return nil }
        if let separator = remainder.range(of: ", ") {
            let sender = String(remainder[..<separator.lowerBound])
            let message = String(remainder[separator.upperBound...])
            return (sender, message.isEmpty ? nil : message)
        }
        return (String(remainder), nil)
    }

    private static func collectTexts(_ node: AXNode, depth: Int, texts: inout [TextNode], images: inout [String]) {
        guard depth < 8 else { return }
        if node.role == kAXStaticTextRole as String, let value = node.value ?? node.descriptionText {
            texts.append(TextNode(identifier: node.identifier, value: value))
        } else if node.role == kAXImageRole as String, let description = node.descriptionText {
            images.append(description)
        }
        for child in node.children {
            collectTexts(child, depth: depth + 1, texts: &texts, images: &images)
        }
    }

    /// The banner description usually reads "AppName, Title, Body". Use its first
    /// component when it names an installed/running app; otherwise try image descriptions.
    private static func resolveAppName(description: String?, images: [String], title: String?, body: String?,
                                       resolveBundleID: (String) -> String?) -> String? {
        var candidates: [String] = []
        if let description {
            if let first = description.components(separatedBy: ", ").first {
                candidates.append(first)
            }
            candidates.append(description)
        }
        candidates.append(contentsOf: images)
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != title, trimmed != body else { continue }
            if resolveBundleID(trimmed) != nil {
                return trimmed
            }
        }
        if let first = description?.components(separatedBy: ", ").first,
           !first.isEmpty, first != title, description?.contains(", ") == true {
            return first
        }
        return nil
    }
}

/// Maps a display name like "Messages" to a bundle identifier.
enum AppNameResolver {
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    static func bundleIdentifier(forAppName name: String) -> String? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolve(name)
        lock.lock()
        cache[name] = resolved
        lock.unlock()
        return resolved
    }

    private static func resolve(_ name: String) -> String? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let bundleID = running.bundleIdentifier {
            return bundleID
        }
        let fileManager = FileManager.default
        let userApplications = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        var folders = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            userApplications
        ]
        // Browser web apps live one level down, e.g. ~/Applications/Brave Browser Apps.localized/Gmail.app.
        for root in ["/Applications", userApplications] {
            let children = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            for child in children where !child.hasSuffix(".app") && !child.hasPrefix(".") {
                folders.append((root as NSString).appendingPathComponent(child))
            }
        }
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).app")
            if let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
                return bundleID
            }
        }
        return nil
    }
}
